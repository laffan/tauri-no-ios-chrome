// NoChromeSceneConfigurator.swift
//
// Hides the iPadOS 26 system chrome (top menu bar + bottom-right resize
// corner) plus the classic status bar (time/battery/wifi) from inside
// Tauri's app target without forking the generated AppDelegate /
// SceneDelegate.
//
// Swift forbids overriding `+load` and `+initialize`, so we can't auto-
// register at runtime load time. Instead, `apply-ios-overrides.mjs` patches
// the generated `AppDelegate.swift` to call `install()` at the top of
// `application(_:didFinishLaunchingWithOptions:)`. That's still early enough
// to receive the very first `UIScene.willConnectNotification`.

import UIKit
import ObjectiveC

@objc(NoChromeSceneConfigurator)
public final class NoChromeSceneConfigurator: NSObject {

    private static var didInstall = false

    /// Idempotent. Safe to call multiple times.
    @objc public static func install() {
        guard !didInstall else { return }
        didInstall = true
        NSLog("[NoChrome] install()")

        // Swizzle UIViewController.prefersStatusBarHidden to always
        // return true. Combined with UIViewControllerBasedStatusBarAppearance
        // = YES in Info.plist, this hides the classic status bar
        // regardless of which VC subclass Tauri's WebView host ends up
        // being.
        installStatusBarHider()

        let center = NotificationCenter.default
        center.addObserver(
            forName: UIScene.willConnectNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let scene = note.object as? UIWindowScene else { return }
            applyNoChrome(to: scene, phase: "willConnect")
        }
        center.addObserver(
            forName: UIScene.didActivateNotification,
            object: nil,
            queue: .main
        ) { note in
            // didActivate fires on every foregrounding; some iPadOS 26
            // chrome may need re-suppressing after backgrounding.
            guard let scene = note.object as? UIWindowScene else { return }
            applyNoChrome(to: scene, phase: "didActivate")
        }
    }

    private static func applyNoChrome(to scene: UIWindowScene, phase: String) {
        NSLog("[NoChrome] applyNoChrome \(phase) scene=\(scene)")

        // 1. Lock the scene's geometry. When the system knows the window
        //    can't be resized, the iPadOS 26 resize-corner affordance is
        //    suppressed.
        if #available(iOS 16.0, *) {
            let prefs = UIWindowScene.GeometryPreferences.iOS()
            scene.requestGeometryUpdate(prefs) { error in
                NSLog("[NoChrome] geometry update error: \(error)")
            }
        }

        // 2. Speculative KVC pokes for chrome-suppression toggles that may
        //    exist on UIWindowScene in the iPadOS 26 SDK. Each call is
        //    guarded by a `responds(to:)` selector check so this is safe
        //    when the property doesn't exist (older SDK or a name we
        //    guessed wrong).
        let setFalse = ["isUserResizable", "prefersStandardWindowControlsVisible"]
        let setTrue = ["prefersFullScreenContent", "isMenuBarHidden", "prefersMenuBarHidden"]

        for key in setFalse {
            if pokeBool(scene: scene, key: key, value: false) {
                NSLog("[NoChrome] set \(key) = false")
            }
        }
        for key in setTrue {
            if pokeBool(scene: scene, key: key, value: true) {
                NSLog("[NoChrome] set \(key) = true")
            }
        }

        // 3. Status bar / home indicator: keep edge-to-edge.
        for window in scene.windows {
            window.rootViewController?.setNeedsStatusBarAppearanceUpdate()
            window.rootViewController?.setNeedsUpdateOfHomeIndicatorAutoHidden()
        }
    }

    /// Returns true if the property existed and was set.
    private static func pokeBool(scene: UIWindowScene, key: String, value: Bool) -> Bool {
        let setterName = "set" + key.prefix(1).uppercased() + key.dropFirst() + ":"
        let setter = NSSelectorFromString(setterName)
        guard scene.responds(to: setter) else { return false }
        scene.setValue(value, forKey: key)
        return true
    }

    /// Replaces the implementation of UIViewController.prefersStatusBarHidden
    /// with a block that always returns true. Subclasses that DON'T override
    /// the property fall through to UIViewController's IMP (now ours).
    /// Subclasses that DO override it are unaffected, but that's fine —
    /// nobody in the Tauri WebView path should be doing that, and if any
    /// of them did, they could only have made the bar hidden, not visible.
    private static func installStatusBarHider() {
        let cls: AnyClass = UIViewController.self
        let sel = #selector(getter: UIViewController.prefersStatusBarHidden)
        guard let method = class_getInstanceMethod(cls, sel) else {
            NSLog("[NoChrome] could not find UIViewController.prefersStatusBarHidden")
            return
        }
        let block: @convention(block) (UIViewController) -> Bool = { _ in true }
        let imp = imp_implementationWithBlock(block)
        method_setImplementation(method, imp)
        NSLog("[NoChrome] swizzled UIViewController.prefersStatusBarHidden -> true")
    }
}
