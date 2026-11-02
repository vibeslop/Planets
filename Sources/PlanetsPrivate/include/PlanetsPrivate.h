#ifndef PLANETS_PRIVATE_H
#define PLANETS_PRIVATE_H

#include <ApplicationServices/ApplicationServices.h>
#include <stdbool.h>

// The CGWindowID behind an Accessibility window element. Private but stable for over a
// decade, and the only link between the Accessibility API and the window server.
AXError _AXUIElementGetWindow(AXUIElementRef element, CGWindowID *outWindowID);

// Makes one specific window of an app key and frontmost through SkyLight, the way a click
// does. Plain app activation would raise every window of the app, not just this one.
// Returns false when the private calls are unavailable, so callers can fall back.
// The app receives a left mouse down and up for it, which it and any event tap can take
// for a real click: a full-screen video or game does.
bool planets_focus_window(pid_t pid, CGWindowID windowID);

// Brings an app forward with one of its windows in front, the way clicking its Dock icon
// does, Space and all, but without the synthetic click: that window isn't made key.
bool planets_front_window(pid_t pid, CGWindowID windowID);

// Makes a process frontmost without choosing a window, like clicking the desktop of an
// app. Used to take focus away from windows parked on hidden workspaces.
bool planets_activate_process(pid_t pid);

// Where the window server has a window right now, in global top-left coordinates. Unlike
// Accessibility, which reports through the owning app and arrives late, this is the
// position being composited, so the glow can keep pace with a window being dragged.
// Falls back to the public window list when SkyLight's call is unavailable.
bool planets_window_bounds(CGWindowID windowID, CGRect *outBounds);

// The process the window server has in front, or -1 when that can't be asked. Safe on
// any thread, unlike NSWorkspace, which the keyboard thread can't use.
pid_t planets_front_process(void);

// The Space a window is on, or 0 when that can't be asked or it's on more than one. A
// full-screen window has a Space of its own; every other window of a display shares its
// desktop Space. A window shown on every Space, such as an overlay covering the display,
// belongs to none of them, and so is never taken for a full-screen window.
uint64_t planets_window_space(CGWindowID windowID);

// The Spaces of the display that has `space`, in Mission Control's order, each with
// whether it's a full-screen Space, and the one in front on that display. With `space` 0,
// the display whose Space is in front. Returns how many were written; 0 when the space
// is on no display or the calls are unavailable.
int planets_display_spaces(uint64_t space, uint64_t *ids, bool *fullScreen, int max, uint64_t *current);

// The Space in front of the active display, or 0 when that can't be asked. One cheap call,
// unlike the whole layout planets_display_spaces copies, so it can be asked every frame.
uint64_t planets_active_space(void);

// Moves `steps` Spaces left or right on the active display at once, with no slide: a
// trackpad swipe flung so hard the Dock lands without animating. Returns false when the
// events couldn't be made. Arrival isn't reported; watch the current Space for it.
bool planets_swipe_spaces(bool rightward, int steps);

#endif
