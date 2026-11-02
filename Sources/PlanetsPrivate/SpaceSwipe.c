// Instant Space switching: a synthetic trackpad swipe between Spaces, flung so hard that
// the Dock lands on the next Space without playing its slide.
//
// The event layout follows InstantSpaceSwitcher, whose authors traced it from real swipes:
//
//   InstantSpaceSwitcher, https://github.com/jurplel/InstantSpaceSwitcher
//   MIT License, Copyright (c) 2026 jurplel
//   Permission is hereby granted, free of charge, to any person obtaining a copy of this
//   software and associated documentation files (the "Software"), to deal in the Software
//   without restriction, including without limitation the rights to use, copy, modify,
//   merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
//   permit persons to whom the Software is furnished to do so, subject to the following
//   conditions: The above copyright notice and this permission notice shall be included in
//   all copies or substantial portions of the Software. THE SOFTWARE IS PROVIDED "AS IS",
//   WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED.
#include "PlanetsPrivate.h"
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>

// Event fields the public headers don't name.
enum {
    fieldEventType = 55,
    fieldGestureHIDType = 110,
    fieldSwipeMotion = 123,
    fieldSwipeProgress = 124,
    fieldSwipePositionX = 125,
    fieldSwipeVelocityX = 129,
    fieldSwipeVelocityY = 130,
    fieldGesturePhase = 132,
    fieldGesturePhaseAlias = 134,
    fieldZoomDeltaY = 138,
    fieldTimestampAlias = 169,
};
enum { eventGesture = 29, eventDockControl = 30 };
enum { hidDockSwipe = 23, motionHorizontal = 1 };
enum { phaseBegan = 1, phaseChanged = 2, phaseEnded = 4 };

static bool macOS27OrLater(void) {
    static int cached = -1;
    if (cached < 0) {
        char version[32] = {0};
        size_t size = sizeof(version);
        cached = sysctlbyname("kern.osproductversion", version, &size, NULL, 0) == 0 && atoi(version) >= 27;
    }
    return cached;
}

// macOS 27 honours a synthetic swipe only with the raw HID event a trackpad would have sent
// appended to it: a fluid-touch gesture, and on the last phase its velocity.
#pragma pack(push, 1)
typedef struct { uint32_t size, type, options; uint8_t depth, reserved[3]; } HIDBase;
typedef struct { HIDBase base; int32_t x, y, z; uint32_t swipeMask; uint16_t motion, flavor; int32_t progress; } HIDFluidGesture;
typedef struct { HIDBase base; int32_t x, y, z; } HIDVelocity;
typedef struct { uint64_t timestamp, sender; uint32_t options, attributeLength, eventCount; } HIDQueueHeader;
#pragma pack(pop)

static int32_t fixed1616(double value) {
    int32_t fixed = (int32_t)(value * 65536.0);
    // The smallest step, rather than none: zero progress isn't a swipe at all.
    return fixed == 0 && value != 0 ? (value > 0 ? 1 : -1) : fixed;
}

static CGEventRef withHIDPayload(CGEventRef event, int phase, double progress, double velocity) {
    CFDataRef data = CGEventCreateData(kCFAllocatorDefault, event);
    if (!data) return NULL;
    const uint8_t *bytes = CFDataGetBytePtr(data);
    CFIndex length = CFDataGetLength(data);
    // Only the serialisation this was traced from, version 2.
    if (length < 4 || bytes[0] || bytes[1] || bytes[2] || bytes[3] != 2) { CFRelease(data); return NULL; }

    bool withVelocity = phase == phaseEnded;
    size_t payloadLength = sizeof(HIDQueueHeader) + sizeof(HIDFluidGesture) + (withVelocity ? sizeof(HIDVelocity) : 0);
    size_t total = (size_t)length + 4 + payloadLength;
    uint8_t *out = calloc(1, total);
    if (!out) { CFRelease(data); return NULL; }
    memcpy(out, bytes, (size_t)length);
    // A tag before the payload: its length, then field 4205, both big-endian.
    out[length] = (uint8_t)(payloadLength >> 8);
    out[length + 1] = (uint8_t)payloadLength;
    out[length + 2] = (uint8_t)(4205 >> 8);
    out[length + 3] = (uint8_t)4205;
    uint8_t *payload = out + length + 4;

    HIDQueueHeader *header = (HIDQueueHeader *)payload;
    uint64_t timestamp = CGEventGetTimestamp(event);
    header->timestamp = timestamp ? timestamp : mach_absolute_time();
    header->eventCount = withVelocity ? 2 : 1;
    HIDFluidGesture *gesture = (HIDFluidGesture *)(payload + sizeof(HIDQueueHeader));
    gesture->base.size = sizeof(HIDFluidGesture);
    gesture->base.type = hidDockSwipe;
    gesture->base.options = (uint32_t)(phase & 0xFF) << 24;
    gesture->x = fixed1616(0.1);
    gesture->motion = motionHorizontal;
    gesture->flavor = 3;  // the Dock's primary swipe
    gesture->progress = fixed1616(progress);
    if (withVelocity) {
        HIDVelocity *v = (HIDVelocity *)(payload + sizeof(HIDQueueHeader) + sizeof(HIDFluidGesture));
        v->base.size = sizeof(HIDVelocity);
        v->base.type = 9;  // velocity
        v->base.depth = 1;
        v->x = fixed1616(velocity);
    }

    CFRelease(data);
    CFDataRef augmented = CFDataCreate(kCFAllocatorDefault, out, (CFIndex)total);
    free(out);
    if (!augmented) return NULL;
    CGEventRef result = CGEventCreateFromData(kCFAllocatorDefault, augmented);
    CFRelease(augmented);
    return result;
}

// The Dock reads a swipe's direction through the natural scrolling setting on macOS 27, so
// the sign follows it. Read each time: a swipe is rare, and the setting can change.
static double direction(bool rightward) {
    Boolean valid = false;
    Boolean natural = CFPreferencesGetAppBooleanValue(CFSTR("com.apple.swipescrolldirection"), kCFPreferencesAnyApplication, &valid);
    double sign = rightward ? -1.0 : 1.0;
    return (!valid || natural) ? sign : -sign;
}

static bool post(int phase, bool rightward, int steps) {
    CGEventRef event = CGEventCreate(NULL);
    if (!event) return false;
    CGEventSetIntegerValueField(event, fieldEventType, eventDockControl);
    CGEventSetIntegerValueField(event, fieldGestureHIDType, hidDockSwipe);
    CGEventSetIntegerValueField(event, fieldGesturePhase, phase);
    CGEventSetIntegerValueField(event, fieldSwipeMotion, motionHorizontal);
    CGEventRef sent = event;
    if (macOS27OrLater()) {
        double sign = direction(rightward);
        // Almost no progress leaves nothing to animate; the fling on the last phase is what
        // commits the change. Full progress also switched, but showed the old Space first.
        double progress = sign * 0.000016, velocity = sign * 9999.0;
        CGEventSetDoubleValueField(event, fieldSwipeProgress, progress);
        CGEventSetIntegerValueField(event, fieldGesturePhaseAlias, phase);
        CGEventSetDoubleValueField(event, fieldZoomDeltaY, 3.0);
        CGEventSetDoubleValueField(event, fieldTimestampAlias, (double)mach_absolute_time());
        CGEventSetDoubleValueField(event, fieldSwipePositionX, 0.1);
        if (phase == phaseEnded) CGEventSetDoubleValueField(event, fieldSwipeVelocityX, velocity);
        sent = withHIDPayload(event, phase, progress, velocity);
        CFRelease(event);
        if (!sent) return false;
    } else {
        double velocity = (rightward ? 2000.0 : -2000.0) * steps;
        CGEventSetDoubleValueField(event, fieldSwipeProgress, rightward ? 0.000016 : -0.000016);
        CGEventSetDoubleValueField(event, fieldSwipeVelocityX, velocity);
        CGEventSetDoubleValueField(event, fieldSwipeVelocityY, velocity);
    }
    CGEventPost(kCGSessionEventTap, sent);
    CFRelease(sent);
    // The Dock ignores the swipe without a plain gesture event beside it.
    CGEventRef companion = CGEventCreate(NULL);
    if (!companion) return false;
    CGEventSetIntegerValueField(companion, fieldEventType, eventGesture);
    CGEventPost(kCGSessionEventTap, companion);
    CFRelease(companion);
    return true;
}

bool planets_swipe_spaces(bool rightward, int steps) {
    for (int i = 0; i < steps; i++) {
        // Three phases: with only began and ended, the Dock waits for more.
        if (!post(phaseBegan, rightward, steps) || !post(phaseChanged, rightward, steps) || !post(phaseEnded, rightward, steps)) return false;
    }
    return true;
}
