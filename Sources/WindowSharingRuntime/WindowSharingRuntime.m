#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>
#import <stdlib.h>
#import <string.h>
#import "WindowSharingRuntime.h"

typedef void (*WSRSharingSetterIMP)(NSWindow *, SEL, NSWindowSharingType);

static WSRSharingSetterIMP originalSharingSetter = NULL;
static BOOL runtimeIsActive = NO;

static void WSRInterceptedSetSharingType(
    NSWindow *window,
    SEL selector,
    NSWindowSharingType requestedType
) {
    WSRSharingSetterIMP original = originalSharingSetter;
    if (original == NULL) return;

    const NSWindowSharingType forwardedType = requestedType == NSWindowSharingNone
        ? NSWindowSharingReadOnly
        : requestedType;
    original(window, selector, forwardedType);
}

static BOOL WSRInstallHook(void) {
    if (runtimeIsActive) return YES;

    Method setter = class_getInstanceMethod(NSWindow.class, @selector(setSharingType:));
    if (setter == NULL) return NO;

    IMP currentImplementation = method_getImplementation(setter);
    if (currentImplementation == (IMP)WSRInterceptedSetSharingType) {
        runtimeIsActive = YES;
        return YES;
    }

    originalSharingSetter = (WSRSharingSetterIMP)currentImplementation;
    method_setImplementation(setter, (IMP)WSRInterceptedSetSharingType);
    runtimeIsActive = YES;
    return YES;
}

static void WSRSetExistingWindowsCapturable(void) {
    if (NSApp == nil) return;
    for (NSWindow *window in NSApp.windows) {
        window.sharingType = NSWindowSharingReadOnly;
    }
}

static BOOL WSRIsOwnedTestHost(void) {
    return [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.codex.wechat-screenshot-restore.testhost"]
        && getenv("WSR_OWNED_TEST_HOST") != NULL
        && strcmp(getenv("WSR_OWNED_TEST_HOST"), "1") == 0;
}

static BOOL WSRIsOfficialWeChat(void) {
    // This hook depends on AppKit's public Objective-C setter, not a WeChat code offset.
    // Version/build are recorded by the installer for visibility, never used as a hook gate.
    return [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.tencent.xinWeChat"];
}

static void WSRActivateProductionRuntime(void) {
    if (!WSRIsOfficialWeChat()) return;
    if (!WSRInstallHook()) return;
    WSRSetExistingWindowsCapturable();
}

@interface WSRRuntimeBootstrap : NSObject
@end

@implementation WSRRuntimeBootstrap

+ (void)load {
    // The production hook is scoped to the official WeChat bundle ID. The owned test host
    // remains opt-in through WSRActivateRuntime() and its explicit marker.
    if (!WSRIsOfficialWeChat()) return;
    if ([NSThread isMainThread]) {
        WSRActivateProductionRuntime();
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            WSRActivateProductionRuntime();
        });
    }
}

@end

int WSRActivateRuntime(void) {
    if (![NSThread isMainThread]) return 1;
    if (NSApp == nil) return 2;
    if (!WSRIsOwnedTestHost()) return 4;
    if (!WSRInstallHook()) return 3;
    WSRSetExistingWindowsCapturable();
    return 0;
}

const char *WSRRuntimeVersion(void) {
    return "1.0";
}
