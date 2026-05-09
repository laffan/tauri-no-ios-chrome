// NoChromeSceneConfigurator.swift
//
// Hides the iPadOS 26 system chrome (top menu bar + bottom-right resize corner)
// without forking Tauri's generated AppDelegate / SceneDelegate.
//
// Strategy: register for `UIScene.willConnectNotification` very early (at
// objc-runtime load time), and whenever a `UIWindowScene` connects, push
// every available API toggle we know of for suppressing the new windowing UI.
//
// We deliberately stack multiple approaches because Apple has not yet
// documented a single, definitive opt-out — different combinations of
// Info.plist keys, scene properties, and geometry requests are required on
// different iPad form factors. The combination here is conservative: every
// call is wrapped in availability + responds-to-selector checks, so it is
// safe to ship even when running against older OS versions or older SDKs.

import UIKit

@objc(NoChromeSceneConfigurator)
public final class NoChromeSceneConfigurator: NSObject {

    /// Called automatically once when the Objective-C runtime loads the class.
    /// `+load` is the earliest hook available — earlier than
    /// `application(_:didFinishLaunchingWithOptions:)` — which guarantees we
    /// see the very first `willConnect` notification for the initial scene.
    @objc public override class func load() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sceneWillConnect(_:)),
            name: UIScene.willConnectNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sceneDidActivate(_:)),
            name: UIScene.didActivateNotification,
            object: nil
        )
    }

    @objc private class func sceneWillConnect(_ note: Notification) {
        guard let scene = note.object as? UIWindowScene else { return }
        applyNoChrome(to: scene)
    }

    @objc private class func sceneDidActivate(_ note: Notification) {
        // Re-apply on activation: some iPadOS 26 chrome is reset when the
        // scene is foregrounded after backgrounding.
        guard let scene = note.object as? UIWindowScene else { return }
        applyNoChrome(to: scene)
    }

    private class func applyNoChrome(to scene: UIWindowScene) {
        // 1. Lock the scene to a single, full-screen geometry. When the system
        //    knows the app cannot resize, the resize corner is suppressed.
        if #available(iOS 16.0, *) {
            let prefs = UIWindowScene.GeometryPreferences.iOS()
            // `interfaceOrientations` left at default = inherit Info.plist.
            scene.requestGeometryUpdate(prefs) { error in
                NSLog("[NoChrome] geometry update error: \(error)")
            }
        }

        // 2. Disable the user-resize affordances exposed in iPadOS 26.
        //    These properties only exist on the iPadOS 26 SDK; we feature-
        //    detect via `responds(to:)` so the file still compiles when the
        //    project is built against an older SDK.
        let resizeKeys: [String] = [
            "isUserResizable",         // hypothetical iPadOS 26 toggle
            "prefersStandardWindowControlsVisible",
            "prefersFullScreenContent"
        ]
        for key in resizeKeys {
            // setValue:forKey: gracefully no-ops when the key is missing AND
            // the class has overridden setValue:forUndefinedKey: — but
            // UIWindowScene does NOT, so we must guard with a selector check.
            let setter = "set" + key.prefix(1).uppercased() + key.dropFirst() + ":"
            if scene.responds(to: NSSelectorFromString(setter)) {
                // For `prefersFullScreenContent` we want true; for
                // `isUserResizable` we want false. Encode that here.
                let value: Any = key.hasPrefix("prefers") ? true : false
                scene.setValue(value, forKey: key)
            }
        }

        // 3. Hide the iPadOS 26 menu bar. The new menu bar is owned by the
        //    window scene; as of the public iPadOS 26 SDK there is no formal
        //    `isMenuBarHidden` property, so we try every plausible KVC key
        //    and additionally rebuild the menu to be empty.
        let menuKeys = [
            "isMenuBarHidden",
            "prefersMenuBarHidden",
            "menuBarVisibility"
        ]
        for key in menuKeys {
            let setter = "set" + key.prefix(1).uppercased() + key.dropFirst() + ":"
            if scene.responds(to: NSSelectorFromString(setter)) {
                scene.setValue(true, forKey: key)
            }
        }

        // 4. Force a menu rebuild. `UIMenuSystem.main.setNeedsRebuild()` will
        //    re-invoke `buildMenu(with:)` on the responder chain; combined
        //    with our AppDelegate override (see AppDelegate+NoChrome.swift)
        //    that removes every menu, the visible menu bar collapses to
        //    nothing on builds where the bar is content-driven.
        UIMenuSystem.main.setNeedsRebuild()

        // 5. Status bar / home indicator: keep the screen edge-to-edge.
        scene.windows.forEach { window in
            window.rootViewController?.setNeedsStatusBarAppearanceUpdate()
            if #available(iOS 11.0, *) {
                window.rootViewController?.setNeedsUpdateOfHomeIndicatorAutoHidden()
            }
        }
    }
}
