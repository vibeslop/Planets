#ifndef PLANETS_PRIVATE_H
#define PLANETS_PRIVATE_H

#include <ApplicationServices/ApplicationServices.h>
#include <stdbool.h>

AXError _AXUIElementGetWindow(AXUIElementRef element, CGWindowID *outWindowID);

bool planets_focus_window(pid_t pid, CGWindowID windowID);

bool planets_front_window(pid_t pid, CGWindowID windowID);

bool planets_activate_process(pid_t pid);

bool planets_window_bounds(CGWindowID windowID, CGRect *outBounds);

pid_t planets_front_process(void);

uint64_t planets_window_space(CGWindowID windowID);

int planets_display_spaces(uint64_t space, uint64_t *ids, bool *fullScreen, int max, uint64_t *current);

uint64_t planets_active_space(void);

bool planets_swipe_spaces(bool rightward, int steps);

#endif
