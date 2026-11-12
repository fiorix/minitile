#ifndef MINITILE_CSKYLIGHT_H
#define MINITILE_CSKYLIGHT_H
#include <ApplicationServices/ApplicationServices.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// Initialize once on the main thread. Reads (Spaces, window IDs, elements by
// number, secure-input status) work from any thread; the bridged operations and
// focus are main-thread only. Copy functions return owned CF objects (or NULL).
bool csl_init(char *error, size_t length);
CFArrayRef csl_copy_managed_display_spaces(void) CF_RETURNS_RETAINED;
uint64_t csl_current_space(CFStringRef display);
CFArrayRef csl_copy_window_spaces(const uint32_t *ids, size_t count) CF_RETURNS_RETAINED;
// Bridged operations have no meaningful server return code. True means submitted.
bool csl_move_windows(const uint32_t *ids, size_t count, uint64_t space);
bool csl_switch_space(CFStringRef display, uint64_t target, uint64_t hide);
bool csl_window_id(AXUIElementRef element, uint32_t *id);
// The element an app numbered `number`, valid or not, since an app's window list
// omits windows on Spaces that are not on screen. NULL when the constructor is
// missing from this macOS.
AXUIElementRef csl_copy_element(int32_t pid, uint64_t number) CF_RETURNS_RETAINED;
bool csl_focus_window(int32_t pid, uint32_t id);
bool csl_symbolic_hotkey(int id, uint16_t *keycode, uint32_t *modifiers, bool *enabled);
bool csl_secure_input_enabled(void);
#endif
