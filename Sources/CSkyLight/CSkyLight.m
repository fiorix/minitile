#import "CSkyLight.h"
#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <objc/runtime.h>

#define SKYLIGHT_PATH "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight"
#define BRIDGED_SYMBOL "__ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP47SLSAsynchronousBridgedWindowManagementOperation"

@interface NSObject (MinitileBridged)
- (instancetype)initWithWindows:(NSArray *)windows spaceID:(uint64_t)space;
- (instancetype)initWithSpaces:(NSArray *)spaces;
- (instancetype)initWithDisplayIdentifier:(NSString *)display spaceID:(uint64_t)space;
@end

static int connection;
static bool ready;
static int (*main_connection)(void);
static CFArrayRef (*managed_spaces)(int);
static CFArrayRef (*window_spaces)(int, int, CFArrayRef);
static uint64_t (*current_space)(int, CFStringRef);
static AXError (*window_id)(AXUIElementRef, uint32_t *);
static CGError (*front_process)(ProcessSerialNumber *, uint32_t, uint32_t);
static CGError (*post_record)(ProcessSerialNumber *, uint8_t *);
static CGError (*hotkey_value)(int, uint16_t *, uint16_t *, uint32_t *);
static bool (*hotkey_enabled)(int);
static int64_t (*perform)(void *);
static Class move_class, show_class, hide_class, current_class;

static void *local_symbol(const char *image, const char *symbol) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name || strcmp(name, image)) continue;
        const struct mach_header_64 *header = (const void *)_dyld_get_image_header(i);
        if (header->magic != MH_MAGIC_64) return NULL;
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        const struct segment_command_64 *linkedit = NULL;
        const struct symtab_command *symtab = NULL;
        const uint8_t *cursor = (const uint8_t *)(header + 1);
        const uint8_t *end = cursor + header->sizeofcmds;
        for (uint32_t c = 0; c < header->ncmds; c++) {
            if ((size_t)(end - cursor) < sizeof(struct load_command)) return NULL;
            const struct load_command *lc = (const void *)cursor;
            if (lc->cmdsize < sizeof(*lc) || lc->cmdsize > (size_t)(end - cursor)) return NULL;
            if (lc->cmd == LC_SEGMENT_64 && lc->cmdsize >= sizeof(struct segment_command_64)) {
                const struct segment_command_64 *segment = (const void *)lc;
                if (!strncmp(segment->segname, SEG_LINKEDIT, sizeof(segment->segname))) linkedit = segment;
            }
            if (lc->cmd == LC_SYMTAB && lc->cmdsize >= sizeof(struct symtab_command)) symtab = (const void *)lc;
            cursor += lc->cmdsize;
        }
        if (!linkedit || !symtab) return NULL;
        uintptr_t base = (uintptr_t)(linkedit->vmaddr - linkedit->fileoff + slide);
        const char *strings = (const char *)(base + symtab->stroff);
        const struct nlist_64 *symbols = (const void *)(base + symtab->symoff);
        for (uint32_t s = 0; s < symtab->nsyms; s++) {
            uint32_t offset = symbols[s].n_un.n_strx;
            if (offset >= symtab->strsize || !symbols[s].n_value) continue;
            if (!memchr(strings + offset, 0, symtab->strsize - offset)) continue;
            if (!strcmp(strings + offset, symbol)) return (void *)(symbols[s].n_value + slide);
        }
    }
    return NULL;
}

static bool missing(char *error, size_t length, const char *name) {
    if (error && length) snprintf(error, length, "SkyLight unavailable: %s", name);
    return false;
}

bool csl_init(char *error, size_t length) {
    if (error && length) error[0] = 0;
    if (ready) return true;
    if (!dlopen(SKYLIGHT_PATH, RTLD_NOW | RTLD_GLOBAL)) return missing(error, length, dlerror());
#define LOAD(target, name) \
    *(void **)&target = dlsym(RTLD_DEFAULT, name); \
    if (!target) return missing(error, length, name)
    LOAD(main_connection, "SLSMainConnectionID");
    LOAD(managed_spaces, "SLSCopyManagedDisplaySpaces");
    LOAD(window_spaces, "SLSCopySpacesForWindows");
    LOAD(current_space, "SLSManagedDisplayGetCurrentSpace");
    LOAD(window_id, "_AXUIElementGetWindow");
    LOAD(front_process, "_SLPSSetFrontProcessWithOptions");
    LOAD(post_record, "SLPSPostEventRecordTo");
    LOAD(hotkey_value, "CGSGetSymbolicHotKeyValue");
    LOAD(hotkey_enabled, "CGSIsSymbolicHotKeyEnabled");
#undef LOAD
    *(void **)&perform = local_symbol(SKYLIGHT_PATH, BRIDGED_SYMBOL);
    if (!perform) return missing(error, length, BRIDGED_SYMBOL);
#define CLASS(target, name, selector) \
    target = objc_getClass(name); \
    if (!target || !class_getInstanceMethod(target, selector)) return missing(error, length, name)
    CLASS(move_class, "SLSBridgedMoveWindowsToManagedSpaceOperation", @selector(initWithWindows:spaceID:));
    CLASS(show_class, "SLSBridgedShowSpacesOperation", @selector(initWithSpaces:));
    CLASS(hide_class, "SLSBridgedHideSpacesOperation", @selector(initWithSpaces:));
    CLASS(current_class, "SLSBridgedManagedDisplaySetCurrentSpaceOperation", @selector(initWithDisplayIdentifier:spaceID:));
#undef CLASS
    connection = main_connection();
    ready = true;
    return true;
}

static NSArray *numbers(const uint32_t *ids, size_t count) {
    NSMutableArray *result = [NSMutableArray arrayWithCapacity:count];
    for (size_t i = 0; i < count; i++) [result addObject:@(ids[i])];
    return result;
}

CFArrayRef csl_copy_managed_display_spaces(void) { return ready ? managed_spaces(connection) : NULL; }
uint64_t csl_current_space(CFStringRef display) { return ready ? current_space(connection, display) : 0; }
CFArrayRef csl_copy_window_spaces(const uint32_t *ids, size_t count) {
    if (!ready || (!ids && count)) return NULL;
    return window_spaces(connection, 0x7, (__bridge CFArrayRef)numbers(ids, count));
}

bool csl_move_windows(const uint32_t *ids, size_t count, uint64_t space) {
    if (!ready || !space || (!ids && count)) return false;
    if (!count) return true;
    @try {
        id op = [[move_class alloc] initWithWindows:numbers(ids, count) spaceID:space];
        if (!op) return false;
        perform((__bridge void *)op);
        return true;
    } @catch (NSException *exception) { return false; }
}

bool csl_switch_space(CFStringRef display, uint64_t target, uint64_t hide) {
    if (!ready || !display || !target || !hide || target == hide) return false;
    @try {
        id show = [[show_class alloc] initWithSpaces:@[@(target)]];
        id conceal = [[hide_class alloc] initWithSpaces:@[@(hide)]];
        id current = [[current_class alloc] initWithDisplayIdentifier:(__bridge NSString *)display spaceID:target];
        if (!show || !conceal || !current) return false;
        perform((__bridge void *)show);
        perform((__bridge void *)conceal);
        perform((__bridge void *)current);
        return true;
    } @catch (NSException *exception) { return false; }
}

bool csl_window_id(AXUIElementRef element, uint32_t *id) {
    return ready && element && id && window_id(element, id) == kAXErrorSuccess && *id != 0;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
bool csl_focus_window(int32_t pid, uint32_t id) {
    if (!ready || !id) return false;
    ProcessSerialNumber psn = {0};
    if (GetProcessForPID(pid, &psn) != noErr) return false;
    CGError front = front_process(&psn, id, 0x200);
    uint8_t record[0xf8] = {0};
    record[0x04] = 0xf8;
    record[0x08] = 0x01;
    record[0x3a] = 0x10;
    memcpy(record + 0x3c, &id, sizeof(id));
    memset(record + 0x20, 0xff, 0x10);
    CGError first = post_record(&psn, record);
    record[0x08] = 0x02;
    CGError second = post_record(&psn, record);
    return front == kCGErrorSuccess && first == kCGErrorSuccess && second == kCGErrorSuccess;
}
#pragma clang diagnostic pop

bool csl_symbolic_hotkey(int id, uint16_t *keycode, uint32_t *modifiers, bool *enabled) {
    if (!ready || !keycode || !modifiers || !enabled) return false;
    uint16_t character;
    if (hotkey_value(id, &character, keycode, modifiers) != kCGErrorSuccess) return false;
    *enabled = hotkey_enabled(id);
    return true;
}

bool csl_secure_input_enabled(void) { return IsSecureEventInputEnabled(); }
