//
// NoChromeBootstrap.m
//
// Pure Objective-C bootstrap that runs at dyld image-load time. We need
// this because Tauri 2.0's iOS template does not generate an
// AppDelegate.swift we can patch — Tauri's app delegate is set up from
// Rust — and Swift forbids overriding +load on NSObject subclasses.
// The Objective-C runtime imposes no such restriction, so this file's
// +load reliably fires very early during launch.
//
// All it does is reach into our Swift class via NSClassFromString and
// invoke +install. Going through the runtime (instead of importing a
// generated `<Module>-Swift.h` header) keeps this file independent of
// Tauri's bridging-header configuration.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

@interface NoChromeBootstrap : NSObject
@end

@implementation NoChromeBootstrap

+ (void)load {
    NSLog(@"[NoChrome] NoChromeBootstrap +load");
    [self triggerInstall];
}

+ (void)triggerInstall {
    Class cls = NSClassFromString(@"NoChromeSceneConfigurator");
    SEL installSel = NSSelectorFromString(@"install");
    if (cls && [cls respondsToSelector:installSel]) {
        NSLog(@"[NoChrome] calling NoChromeSceneConfigurator.install() from +load");
        ((void (*)(id, SEL))objc_msgSend)((id)cls, installSel);
        return;
    }
    // Within a single image, +load runs after all class registration in
    // that image, so NSClassFromString should always succeed when the
    // Swift class is in the same target. We defer just in case the
    // Swift class lives in a different image that hasn't been loaded
    // yet — main-queue dispatch guarantees we run after UIApplicationMain
    // has finished class registration for everything dyld pulled in.
    NSLog(@"[NoChrome] Swift class not yet available at +load, deferring");
    dispatch_async(dispatch_get_main_queue(), ^{
        Class cls2 = NSClassFromString(@"NoChromeSceneConfigurator");
        SEL sel2 = NSSelectorFromString(@"install");
        if (cls2 && [cls2 respondsToSelector:sel2]) {
            NSLog(@"[NoChrome] deferred install() succeeded");
            ((void (*)(id, SEL))objc_msgSend)((id)cls2, sel2);
        } else {
            NSLog(@"[NoChrome] ERROR: NoChromeSceneConfigurator never appeared");
        }
    });
}

@end
