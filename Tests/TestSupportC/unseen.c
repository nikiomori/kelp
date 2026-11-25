// Windows a test opens are never seen: a test puts real windows and panels on screen (a sheet needs one, the agent
// strip floats), and dozens of them blinking over the screen through a run are hard on the eyes. Each window is made
// see-through in the window server, while Kelp's code and the tests read and set `alphaValue` as ever: the value asked
// for is kept beside the window and read back, and the window server always gets 0. AppKit itself is told the real 0:
// a deferred window takes its alpha from the getter when its window-server window is made. (Load-time code, so it holds
// for every window, a test's own or one Kelp makes; only where AppKit is loaded.)
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CGGeometry.h>
#include <dlfcn.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <string.h>

static char wantedKey;
static IMP originalInit, originalSet, originalGet;

static void setAlpha(id self, SEL cmd, CGFloat alpha) {
    CFNumberRef wanted = CFNumberCreate(NULL, kCFNumberCGFloatType, &alpha);
    objc_setAssociatedObject(self, &wantedKey, (id)wanted, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CFRelease(wanted);
    ((void (*)(id, SEL, CGFloat))originalSet)(self, cmd, 0);
}

// Whether the code at `caller` is the system's (AppKit, Foundation's key-value coding, Core Animation).
static int fromTheSystem(const void *caller) {
    Dl_info info;
    return dladdr(caller, &info) && info.dli_fname && strncmp(info.dli_fname, "/System/", 8) == 0;
}

static CGFloat alpha(id self, SEL cmd) {
    CGFloat real = ((CGFloat (*)(id, SEL))originalGet)(self, cmd), value;
    if (fromTheSystem(__builtin_return_address(0))) return real;
    CFNumberRef wanted = (CFNumberRef)objc_getAssociatedObject(self, &wantedKey);
    return wanted && CFNumberGetValue(wanted, kCFNumberCGFloatType, &value) ? value : real;
}

static id initWindow(id self, SEL cmd, CGRect rect, unsigned long style, unsigned long backing, BOOL defer) {
    id window = ((id (*)(id, SEL, CGRect, unsigned long, unsigned long, BOOL))originalInit)(
        self, cmd, rect, style, backing, defer);
    if (window) {
        setAlpha(window, sel_registerName("setAlphaValue:"), alpha(window, sel_registerName("alphaValue")));
        // No zoom or fade of AppKit's own, which runs past `alphaValue`: NSWindowAnimationBehaviorNone, and no sheet
        // sliding in (AppKit's own switch; NSAutomaticWindowAnimationsEnabled, in isolate.c, is off too).
        ((void (*)(id, SEL, long))objc_msgSend)(window, sel_registerName("setAnimationBehavior:"), 2);
        SEL noSheetMotion = sel_registerName("_setDisableSheetAnimation:");
        if (class_respondsToSelector(object_getClass(window), noSheetMotion)) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(window, noSheetMotion, YES);
        }
    }
    return window;
}

static IMP swap(Class window, const char *name, IMP to) {
    Method method = class_getInstanceMethod(window, sel_registerName(name));
    return method ? method_setImplementation(method, to) : NULL;
}

__attribute__((constructor)) static void kelp_unseen_windows(void) {
    Class window = objc_getClass("NSWindow");
    if (!window) return;   // a test bundle without AppKit has no windows
    originalGet = swap(window, "alphaValue", (IMP)alpha);
    originalSet = swap(window, "setAlphaValue:", (IMP)setAlpha);
    originalInit = swap(window, "initWithContentRect:styleMask:backing:defer:", (IMP)initWindow);
}
