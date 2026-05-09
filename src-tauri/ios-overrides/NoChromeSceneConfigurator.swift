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
// `application(_:didFinishLaunchingWithOptions:)`.
//
// Currently the file also installs an on-screen diagnostic overlay so we
// can iterate without `tauri ios dev` / Console.app access — see
// `showDiagnosticsOverlay`. Tap "Copy & Hide" to put the report on the
// clipboard and remove the overlay.

import UIKit
import ObjectiveC

@objc(NoChromeSceneConfigurator)
public final class NoChromeSceneConfigurator: NSObject {

    private static var didInstall = false
    private static var lastDiagnosticText: String = ""
    private static var pollTimer: Timer?
    private static let overlayTag = 0xC0DEBABE

    /// Idempotent. Safe to call multiple times.
    @objc public static func install() {
        guard !didInstall else { return }
        didInstall = true
        NSLog("[NoChrome] install()")

        // Base-class swizzle for any VC that doesn't override either
        // getter. Per-class swizzles for the rootVC happen in
        // applyNoChrome where we know the actual class.
        forceStatusBarHidden(on: UIViewController.self)
        forceChildForStatusBarHiddenNil(on: UIViewController.self)

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
            guard let scene = note.object as? UIWindowScene else { return }
            applyNoChrome(to: scene, phase: "didActivate")
        }

        // Polling safety net: re-apply chrome-hide and try to show the
        // overlay every 0.5s. Survives the scene-observer-doesn't-fire
        // case AND the rootVC-is-nil-when-observer-fires case. Stops
        // itself once the overlay is up.
        DispatchQueue.main.async {
            pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
                for s in UIApplication.shared.connectedScenes {
                    guard let scene = s as? UIWindowScene else { continue }
                    applyNoChrome(to: scene, phase: "poll")
                }
                if overlayIsUp() {
                    NSLog("[NoChrome] overlay is up; stopping poll timer")
                    timer.invalidate()
                    pollTimer = nil
                }
            }
            // Fire once immediately so we don't wait 0.5s for the first
            // run.
            pollTimer?.fire()
        }
    }

    private static func overlayIsUp() -> Bool {
        for s in UIApplication.shared.connectedScenes {
            guard let ws = s as? UIWindowScene else { continue }
            for w in ws.windows where w.viewWithTag(overlayTag) != nil {
                return true
            }
        }
        return false
    }

    private static func applyNoChrome(to scene: UIWindowScene, phase: String) {
        NSLog("[NoChrome] applyNoChrome \(phase) scene=\(scene)")

        // 1. Lock the scene's geometry. When the system knows the window
        //    can't be resized, the iPadOS 26 resize-corner affordance is
        //    suppressed — in theory.
        if #available(iOS 16.0, *) {
            let prefs = UIWindowScene.GeometryPreferences.iOS()
            scene.requestGeometryUpdate(prefs) { error in
                NSLog("[NoChrome] geometry update error: \(error)")
            }
        }

        // 2. Speculative KVC pokes for chrome-suppression toggles that may
        //    exist on UIWindowScene in the iPadOS 26 SDK. Each call is
        //    guarded by a `responds(to:)` selector check.
        let setFalse = ["isUserResizable", "prefersStandardWindowControlsVisible"]
        let setTrue = ["prefersFullScreenContent", "isMenuBarHidden", "prefersMenuBarHidden"]
        for key in setFalse { _ = pokeBool(scene: scene, key: key, value: false) }
        for key in setTrue { _ = pokeBool(scene: scene, key: key, value: true) }

        // 3. Status bar: aggressive override on the actual rootVC class
        //    AND every class in the childForStatusBarHidden chain.
        for window in scene.windows {
            guard let rootVC = window.rootViewController else { continue }
            walkAndForceStatusBarHidden(rootVC)
            rootVC.setNeedsStatusBarAppearanceUpdate()
            rootVC.setNeedsUpdateOfHomeIndicatorAutoHidden()
        }

        // 4. Show the diagnostic overlay AFTER everything above. Brief
        //    delay so async APIs (requestGeometryUpdate, status bar
        //    appearance update) settle and the snapshot reflects the
        //    post-attempt state.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            showDiagnosticsOverlay(in: scene, phase: phase)
        }
    }

    // MARK: - Status-bar swizzles

    /// Walk the rootVC's child / presented hierarchy and force-override
    /// `prefersStatusBarHidden=true` and `childForStatusBarHidden=nil`
    /// on every distinct class encountered. Idempotent.
    private static func walkAndForceStatusBarHidden(_ root: UIViewController) {
        var stack: [UIViewController] = [root]
        var visitedClasses: Set<ObjectIdentifier> = []
        while let vc = stack.popLast() {
            let cls: AnyClass = type(of: vc)
            let id = ObjectIdentifier(cls)
            if !visitedClasses.contains(id) {
                visitedClasses.insert(id)
                forceStatusBarHidden(on: cls)
                forceChildForStatusBarHiddenNil(on: cls)
            }
            stack.append(contentsOf: vc.children)
            if let presented = vc.presentedViewController {
                stack.append(presented)
            }
        }
    }

    private static func forceStatusBarHidden(on cls: AnyClass) {
        let sel = #selector(getter: UIViewController.prefersStatusBarHidden)
        guard let inherited = class_getInstanceMethod(cls, sel) else {
            NSLog("[NoChrome] no prefersStatusBarHidden on \(cls)")
            return
        }
        let typeEncoding = method_getTypeEncoding(inherited)
        let block: @convention(block) (UIViewController) -> Bool = { _ in true }
        let imp = imp_implementationWithBlock(block)
        class_replaceMethod(cls, sel, imp, typeEncoding)
    }

    private static func forceChildForStatusBarHiddenNil(on cls: AnyClass) {
        let sel = #selector(getter: UIViewController.childForStatusBarHidden)
        guard let inherited = class_getInstanceMethod(cls, sel) else { return }
        let typeEncoding = method_getTypeEncoding(inherited)
        let block: @convention(block) (UIViewController) -> UIViewController? = { _ in nil }
        let imp = imp_implementationWithBlock(block)
        class_replaceMethod(cls, sel, imp, typeEncoding)
    }

    // MARK: - Scene KVC pokes

    private static func pokeBool(scene: UIWindowScene, key: String, value: Bool) -> Bool {
        let setterName = "set" + key.prefix(1).uppercased() + key.dropFirst() + ":"
        let setter = NSSelectorFromString(setterName)
        guard scene.responds(to: setter) else { return false }
        scene.setValue(value, forKey: key)
        NSLog("[NoChrome] set \(key) = \(value)")
        return true
    }

    // MARK: - Diagnostic collection

    private static func collectDiagnostics(
        scene: UIWindowScene, rootVC: UIViewController?, phase: String
    ) -> String {
        var L: [String] = []
        L.append("== NoChrome diagnostic (phase=\(phase)) ==")
        L.append("buildTime: \(executableModificationTime())")
        L.append("iOS: \(UIDevice.current.systemVersion)  device: \(UIDevice.current.model)")

        L.append("")
        L.append("--- Info.plist (post-merge) ---")
        let info = Bundle.main.infoDictionary ?? [:]
        let plistKeys = [
            "UIStatusBarHidden",
            "UIViewControllerBasedStatusBarAppearance",
            "UIRequiresFullScreen",
            "UIDesignRequiresCompatibility",
            "UIApplicationSupportsMultipleScenes",
            "UISupportedInterfaceOrientations~ipad",
        ]
        for k in plistKeys {
            let v = info[k].map { "\($0)" } ?? "<unset>"
            L.append("\(k): \(v)")
        }

        L.append("")
        L.append("--- Scene ---")
        L.append("class: \(type(of: scene))")
        L.append("activationState: \(scene.activationState.rawValue)")
        L.append("frame: \(scene.coordinateSpace.bounds)")
        let sbm = scene.statusBarManager
        if let sbm {
            L.append("statusBarManager.isStatusBarHidden: \(sbm.isStatusBarHidden)")
            L.append("statusBarManager.statusBarFrame: \(sbm.statusBarFrame)")
            L.append("statusBarManager.statusBarStyle.rawValue: \(sbm.statusBarStyle.rawValue)")
        } else {
            L.append("statusBarManager: nil")
        }

        L.append("")
        L.append("--- UIWindowScene properties (responds-to) ---")
        let probes = [
            "isUserResizable",
            "prefersStandardWindowControlsVisible",
            "prefersFullScreenContent",
            "isMenuBarHidden",
            "prefersMenuBarHidden",
            "menuBarVisibility",
            "preferredWindowingControlStyle",
            "sizeRestrictions",
            "windowingBehaviors",
        ]
        for k in probes {
            let setterName = "set" + k.prefix(1).uppercased() + k.dropFirst() + ":"
            let setterSel = NSSelectorFromString(setterName)
            let getterSel = NSSelectorFromString(k)
            let s = scene.responds(to: setterSel) ? "Y" : "n"
            let g = scene.responds(to: getterSel) ? "Y" : "n"
            L.append("\(k): get=\(g) set=\(s)")
        }

        L.append("")
        L.append("--- RootViewController ---")
        if let rootVC = rootVC {
            L.append("class: \(type(of: rootVC))")
            L.append("prefersStatusBarHidden: \(rootVC.prefersStatusBarHidden)")
            L.append("prefersHomeIndicatorAutoHidden: \(rootVC.prefersHomeIndicatorAutoHidden)")
            let childCls = rootVC.childForStatusBarHidden.map { String(describing: type(of: $0)) } ?? "nil"
            L.append("childForStatusBarHidden: \(childCls)")
            L.append("modalPresentationCapturesStatusBarAppearance: \(rootVC.modalPresentationCapturesStatusBarAppearance)")
            L.append("--- VC tree ---")
            walkVCs(rootVC, depth: 1, into: &L)
        } else {
            L.append("(nil)")
        }

        return L.joined(separator: "\n")
    }

    private static func walkVCs(_ vc: UIViewController, depth: Int, into lines: inout [String]) {
        let indent = String(repeating: "  ", count: depth)
        for child in vc.children {
            let childCls = child.childForStatusBarHidden.map { String(describing: type(of: $0)) } ?? "nil"
            lines.append("\(indent)- \(type(of: child)) prefersStatusBarHidden=\(child.prefersStatusBarHidden) childForStatusBarHidden=\(childCls)")
            walkVCs(child, depth: depth + 1, into: &lines)
        }
        if let presented = vc.presentedViewController {
            lines.append("\(indent)[presented] \(type(of: presented)) prefersStatusBarHidden=\(presented.prefersStatusBarHidden)")
            walkVCs(presented, depth: depth + 1, into: &lines)
        }
    }

    private static func executableModificationTime() -> String {
        guard let path = Bundle.main.executablePath,
              let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let date = attrs[.modificationDate] as? Date else {
            return "<unknown>"
        }
        return ISO8601DateFormatter().string(from: date)
    }

    // MARK: - On-screen overlay

    private static func showDiagnosticsOverlay(in scene: UIWindowScene, phase: String) {
        let candidates = scene.windows
        guard let window = candidates.first(where: { $0.isKeyWindow }) ?? candidates.first else {
            NSLog("[NoChrome] no window in scene, skipping overlay (phase=\(phase))")
            return
        }
        let rootVC = window.rootViewController
        let report = collectDiagnostics(scene: scene, rootVC: rootVC, phase: phase)
        lastDiagnosticText = report
        NSLog("[NoChrome] diagnostic (\(phase))\n\(report)")

        // Idempotent: if the overlay is already up, just refresh its text.
        if let existing = window.viewWithTag(overlayTag),
           let textView = existing.subviews.compactMap({ $0 as? UITextView }).first {
            textView.text = report
            return
        }

        let container = UIView()
        container.tag = overlayTag
        container.frame = window.bounds
        container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.backgroundColor = .black
        // Conspicuous red border so it's obvious the overlay is present.
        container.layer.borderColor = UIColor.red.cgColor
        container.layer.borderWidth = 4

        let copyButton = UIButton(type: .system)
        copyButton.setTitle("Tap to copy & hide", for: .normal)
        copyButton.setTitleColor(.white, for: .normal)
        copyButton.backgroundColor = UIColor(red: 0.15, green: 0.4, blue: 0.7, alpha: 1)
        copyButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        let buttonHeight: CGFloat = 60
        copyButton.frame = CGRect(x: 0, y: 0, width: container.bounds.width, height: buttonHeight)
        copyButton.autoresizingMask = [.flexibleWidth]
        copyButton.addAction(UIAction(handler: { _ in
            UIPasteboard.general.string = lastDiagnosticText
            for s in UIApplication.shared.connectedScenes {
                guard let ws = s as? UIWindowScene else { continue }
                for w in ws.windows {
                    w.viewWithTag(overlayTag)?.removeFromSuperview()
                }
            }
        }), for: .touchUpInside)

        let textView = UITextView()
        textView.text = report
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .black
        textView.textColor = .white
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.frame = CGRect(
            x: 0, y: buttonHeight,
            width: container.bounds.width,
            height: container.bounds.height - buttonHeight
        )
        textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        textView.contentInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        textView.alwaysBounceVertical = true

        container.addSubview(textView)
        container.addSubview(copyButton)
        // Add to the UIWindow itself so we sit above whatever VC tree
        // (and WebView) Tauri builds.
        window.addSubview(container)
        window.bringSubviewToFront(container)
    }
}
