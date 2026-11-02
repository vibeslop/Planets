#include "PlanetsPrivate.h"
#include <dlfcn.h>
#include <dispatch/dispatch.h>
#include <string.h>

typedef CGError (*SetFrontProcessFn)(ProcessSerialNumber *, uint32_t, uint32_t);
typedef CGError (*PostEventRecordFn)(ProcessSerialNumber *, uint8_t *);
typedef int (*MainConnectionFn)(void);
typedef CGError (*GetWindowBoundsFn)(int, uint32_t, CGRect *);
typedef CGError (*GetFrontProcessFn)(ProcessSerialNumber *);
typedef CFArrayRef (*CopySpacesForWindowsFn)(int, int, CFArrayRef);
typedef CFArrayRef (*CopyDisplaySpacesFn)(int);
typedef uint64_t (*GetActiveSpaceFn)(int);

static SetFrontProcessFn setFrontProcess;
static PostEventRecordFn postEventRecord;
static MainConnectionFn mainConnection;
static GetWindowBoundsFn getWindowBounds;
static GetFrontProcessFn getFrontProcess;
static CopySpacesForWindowsFn copySpacesForWindows;
static CopyDisplaySpacesFn copyDisplaySpaces;
static GetActiveSpaceFn getActiveSpace;

static void load(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *skylight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
        if (!skylight) return;
        setFrontProcess = (SetFrontProcessFn)dlsym(skylight, "_SLPSSetFrontProcessWithOptions");
        postEventRecord = (PostEventRecordFn)dlsym(skylight, "SLPSPostEventRecordTo");
        mainConnection = (MainConnectionFn)dlsym(skylight, "SLSMainConnectionID");
        getWindowBounds = (GetWindowBoundsFn)dlsym(skylight, "SLSGetWindowBounds");
        getFrontProcess = (GetFrontProcessFn)dlsym(skylight, "_SLPSGetFrontProcess");
        copySpacesForWindows = (CopySpacesForWindowsFn)dlsym(skylight, "SLSCopySpacesForWindows");
        copyDisplaySpaces = (CopyDisplaySpacesFn)dlsym(skylight, "SLSCopyManagedDisplaySpaces");
        getActiveSpace = (GetActiveSpaceFn)dlsym(skylight, "SLSGetActiveSpace");
    });
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static bool psn_for_pid(pid_t pid, ProcessSerialNumber *psn) {
    return GetProcessForPID(pid, psn) == noErr;
}
#pragma clang diagnostic pop

static bool front_window(ProcessSerialNumber *psn, CGWindowID windowID) {
    // 0x200 is kCPSUserGenerated: the switch counts as user-initiated, so macOS honours it.
    return setFrontProcess && setFrontProcess(psn, windowID, 0x200) == kCGErrorSuccess;
}

bool planets_front_window(pid_t pid, CGWindowID windowID) {
    load();
    ProcessSerialNumber psn;
    return psn_for_pid(pid, &psn) && front_window(&psn, windowID);
}

bool planets_focus_window(pid_t pid, CGWindowID windowID) {
    load();
    ProcessSerialNumber psn;
    if (!postEventRecord || !psn_for_pid(pid, &psn) || !front_window(&psn, windowID)) return false;
    // Two synthetic window-server events make the window key, the same pair a click sends.
    // Layout taken from yabai, which has used it since macOS 10.13.
    uint8_t bytes[0xf8];
    memset(bytes, 0, sizeof(bytes));
    bytes[0x04] = 0xf8;
    bytes[0x3a] = 0x10;
    memcpy(bytes + 0x3c, &windowID, sizeof(uint32_t));
    memset(bytes + 0x20, 0xff, 0x10);
    bytes[0x08] = 0x01;
    postEventRecord(&psn, bytes);
    bytes[0x08] = 0x02;
    postEventRecord(&psn, bytes);
    return true;
}

bool planets_activate_process(pid_t pid) {
    load();
    if (!setFrontProcess) return false;
    ProcessSerialNumber psn;
    if (!psn_for_pid(pid, &psn)) return false;
    // 0x400 is kCPSNoWindows: bring the process forward without raising any window.
    return setFrontProcess(&psn, 0, 0x400) == kCGErrorSuccess;
}

bool planets_window_bounds(CGWindowID windowID, CGRect *outBounds) {
    load();
    if (mainConnection && getWindowBounds) {
        return getWindowBounds(mainConnection(), windowID, outBounds) == kCGErrorSuccess;
    }
    const void *values[] = { (const void *)(uintptr_t)windowID };
    CFArrayRef ids = CFArrayCreate(NULL, values, 1, NULL);
    CFArrayRef list = CGWindowListCreateDescriptionFromArray(ids);
    CFRelease(ids);
    bool found = false;
    if (list && CFArrayGetCount(list) > 0) {
        CFDictionaryRef info = CFArrayGetValueAtIndex(list, 0);
        CFDictionaryRef bounds = CFDictionaryGetValue(info, kCGWindowBounds);
        found = bounds && CGRectMakeWithDictionaryRepresentation(bounds, outBounds);
    }
    if (list) CFRelease(list);
    return found;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
pid_t planets_front_process(void) {
    load();
    if (!getFrontProcess) return -1;
    ProcessSerialNumber psn;
    if (getFrontProcess(&psn) != kCGErrorSuccess) return -1;
    pid_t pid = -1;
    if (GetProcessPID(&psn, &pid) != noErr) return -1;
    return pid;
}
#pragma clang diagnostic pop

uint64_t planets_window_space(CGWindowID windowID) {
    load();
    if (!mainConnection || !copySpacesForWindows) return 0;
    CFNumberRef number = CFNumberCreate(NULL, kCFNumberSInt32Type, &windowID);
    CFArrayRef ids = CFArrayCreate(NULL, (const void **)&number, 1, &kCFTypeArrayCallBacks);
    CFRelease(number);
    // 7: every kind of Space the window can be on.
    CFArrayRef spaces = copySpacesForWindows(mainConnection(), 7, ids);
    CFRelease(ids);
    uint64_t space = 0;
    if (spaces && CFArrayGetCount(spaces) == 1) {
        CFNumberGetValue(CFArrayGetValueAtIndex(spaces, 0), kCFNumberSInt64Type, &space);
    }
    if (spaces) CFRelease(spaces);
    return space;
}

static uint64_t space_id(CFDictionaryRef space) {
    uint64_t id = 0;
    CFNumberRef number = space ? CFDictionaryGetValue(space, CFSTR("ManagedSpaceID")) : NULL;
    if (number) CFNumberGetValue(number, kCFNumberSInt64Type, &id);
    return id;
}

int planets_display_spaces(uint64_t space, uint64_t *ids, bool *fullScreen, int max, uint64_t *current) {
    load();
    if (!mainConnection || !copyDisplaySpaces) return 0;
    if (space == 0 && getActiveSpace) space = getActiveSpace(mainConnection());
    CFArrayRef displays = copyDisplaySpaces(mainConnection());
    if (!displays) return 0;
    int count = 0;
    for (CFIndex d = 0; d < CFArrayGetCount(displays) && count == 0; d++) {
        CFDictionaryRef display = CFArrayGetValueAtIndex(displays, d);
        CFArrayRef spaces = CFDictionaryGetValue(display, CFSTR("Spaces"));
        if (!spaces) continue;
        bool has = false;
        for (CFIndex i = 0; i < CFArrayGetCount(spaces); i++) {
            if (space_id(CFArrayGetValueAtIndex(spaces, i)) == space) { has = true; break; }
        }
        if (!has) continue;
        for (CFIndex i = 0; i < CFArrayGetCount(spaces) && count < max; i++) {
            CFDictionaryRef entry = CFArrayGetValueAtIndex(spaces, i);
            int type = 0;
            CFNumberRef number = CFDictionaryGetValue(entry, CFSTR("type"));
            if (number) CFNumberGetValue(number, kCFNumberIntType, &type);
            ids[count] = space_id(entry);
            // Type 4 is a full-screen Space; 0 a desktop.
            fullScreen[count] = type == 4;
            count++;
        }
        *current = space_id(CFDictionaryGetValue(display, CFSTR("Current Space")));
    }
    CFRelease(displays);
    return count;
}

uint64_t planets_active_space(void) {
    load();
    return getActiveSpace && mainConnection ? getActiveSpace(mainConnection()) : 0;
}
