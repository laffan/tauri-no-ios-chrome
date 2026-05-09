// AppDelegate+NoChrome.swift
//
// Strips every system menu out of the responder chain so the iPadOS 26 menu
// bar (which is built from `UIMenuBuilder`) renders empty. Combined with the
// `Info.plist` keys that hide an empty bar, this gives a chrome-free
// presentation without forking Tauri's generated `AppDelegate`.
//
// Implementation: swizzle `UIResponder.buildMenu(with:)` at +load time.
// Swift extensions can't override an existing method on a non-final ObjC
// class, so we go through the Objective-C runtime directly.

import UIKit
import ObjectiveC

@objc(NoChromeMenuSwizzler)
public final class NoChromeMenuSwizzler: NSObject {

    @objc public override class func load() {
        installSwizzle()
    }

    private static let installSwizzle: () -> Void = {
        let target: AnyClass = UIResponder.self
        let original = #selector(UIResponder.buildMenu(with:))
        let replacement = #selector(NoChromeMenuSwizzler.nochrome_buildMenu(with:))

        guard
            let originalMethod = class_getInstanceMethod(target, original),
            let replacementMethod = class_getInstanceMethod(NoChromeMenuSwizzler.self, replacement)
        else {
            NSLog("[NoChrome] failed to resolve buildMenu(with:) for swizzle")
            return {}
        }

        // Add the replacement IMP to UIResponder under the original selector.
        // If it's already present (subclass override), fall back to exchange.
        let didAdd = class_addMethod(
            target,
            original,
            method_getImplementation(replacementMethod),
            method_getTypeEncoding(replacementMethod)
        )
        if didAdd {
            // Re-route the replacement selector on UIResponder to the
            // original IMP so callers of `nochrome_buildMenu` reach the real
            // (empty) UIResponder implementation.
            class_replaceMethod(
                target,
                replacement,
                method_getImplementation(originalMethod),
                method_getTypeEncoding(originalMethod)
            )
        } else {
            method_exchangeImplementations(originalMethod, replacementMethod)
        }
        return {}
    }()

    /// Replacement implementation. `self` is the actual responder being asked
    /// to build the menu (AppDelegate, view controller, etc.), not the
    /// swizzler. We strip every standard menu, then chain to the original
    /// implementation in case the responder has its own additions.
    @objc dynamic func nochrome_buildMenu(with builder: UIMenuBuilder) {
        let identifiers: [UIMenu.Identifier] = [
            .application,
            .file,
            .edit,
            .view,
            .window,
            .help,
            .services,
            .hide,
            .quit,
            .newScene,
            .openRecent,
            .close,
            .print,
            .undoRedo,
            .standardEdit,
            .replace,
            .share,
            .textStyle,
            .spelling,
            .spellingPanel,
            .spellingOptions,
            .substitutions,
            .substitutionsPanel,
            .substitutionOptions,
            .transformations,
            .speech,
            .lookup,
            .learn,
            .format,
            .font,
            .textSize,
            .textColor,
            .textStylePasteboard,
            .text,
            .writingDirection,
            .alignment,
            .toolbar,
            .fullscreen,
            .minimizeAndZoom,
            .bringAllToFront,
            .root
        ]
        for id in identifiers {
            builder.remove(menu: id)
        }
        // After the swizzle, this selector points to the *original*
        // UIResponder implementation, so we still call up the chain.
        self.nochrome_buildMenu(with: builder)
    }
}
