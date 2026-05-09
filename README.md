# tauri-no-ios-chrome

A bare-bones Tauri 2.0 app whose only job is to figure out the right
combination of `Info.plist` keys and Swift code needed to hide the new
iPadOS 26 system chrome — the top **menu bar** and the bottom-right
**window resize corner**.

The app itself is a blank page that paints **black in dark mode** and
**white in light mode** (driven by the system's `prefers-color-scheme`).
That makes it easy to verify visually that nothing the OS is drawing
on top of us — bar, divider, corner glyph, status indicator — is showing.

> **Status:** builds and runs on a real iPad (iPad Pro 5G 12.9",
> iPadOS 26). Status bar (time/battery/wifi) was still showing after
> two prior swizzle passes — the most likely remaining cause is that
> Tauri's WebView host returns a child via `childForStatusBarHidden`
> and the system queries the child instead of the VC we swizzled.
> The current build now (a) walks the entire VC tree at scene
> activation and overrides both `prefersStatusBarHidden` and
> `childForStatusBarHidden` on every distinct class encountered, and
> (b) shows an **on-screen diagnostic overlay** (since `tauri ios dev`
> isn't available, Console.app isn't either). The overlay reports the
> rootVC's class, the VC tree, the post-merge Info.plist values, the
> scene's `statusBarManager.isStatusBarHidden`, and which speculative
> `UIWindowScene` properties actually exist on the SDK. Tap "Tap to
> copy & hide" to clipboard-copy the report and dismiss the overlay.
> The README is the running log; expect it to change.
>
> **Icons:** `src-tauri/icons/` contains solid-black PNG placeholders
> (Tauri's `generate_context!` macro fails the build if any referenced
> icon is missing). Replace with real artwork when ready, or run
> `npm run tauri -- icon path/to/source.png` to regenerate the full
> set.

## Strategy, in one paragraph

The premise we started from — "Drafts has hidden the new menu bar" —
turned out to be wrong: the iPadOS 26 menu bar is **already hidden by
default** in Windowed Apps mode and only appears when the pointer
reaches the top edge or the user swipes down. Drafts isn't fighting
the system; it's the steady-state behavior. So our actual job is
narrower than originally scoped:

- Hide the **classic status bar** (time/battery/wifi). Drafts hides
  it; the iPadOS 26 default leaves it visible.
- Hide the **bottom-right resize corner**. Apple has not shipped a
  public opt-out for this; what we ship is best-effort.
- Don't fight the menu bar — let the system auto-hide it.

Apple's WWDC25 session 282 ("Make your UIKit app more flexible") and
[Developer Forums thread 787227](https://developer.apple.com/forums/thread/787227)
both confirm: the official guidance for iPadOS 26 is to *adapt* to the
new chrome via `preferredWindowingControlStyle(for:)` and
`UIView.layoutGuide(for: .margins(cornerAdaptation:))`, not to
suppress it. There's no documented hide flag. `UIDesignRequiresCompatibility = YES`
sounds like the silver bullet but is reportedly unreliable
([dotnet/maui#32814](https://github.com/dotnet/maui/issues/32814)).
`UIRequiresFullScreen` is deprecated in iPadOS 26 and slated to be
ignored. We keep both as no-cost hedges and rely on the items below
for actual effect:

1. **`Info.plist` keys** that opt the app out of the new windowing UI
   entirely. The most likely silver bullet is
   `UIDesignRequiresCompatibility = YES`, which keeps the app on the
   iOS 18 design language. We back it up with `UIRequiresFullScreen`
   and `UIApplicationSupportsMultipleScenes = NO`.
2. **A Swift bridge** — `NoChromeSceneConfigurator.swift` — exposes a
   single `install()` static method. It registers
   `UIScene.willConnectNotification` / `didActivateNotification`
   observers, walks the resulting VC tree on each callback, and
   force-overrides `prefersStatusBarHidden=true` plus
   `childForStatusBarHidden=nil` on every distinct VC class
   encountered. Also pokes a list of speculative `UIWindowScene`
   properties (`isUserResizable`, `prefersFullScreenContent`, …) under
   `responds(to:)` guards so the file compiles against any SDK.

3. **An Obj-C bootstrap** — `NoChromeBootstrap.m` — that has a
   `+load` method which runs at dyld image-load time and calls
   `NoChromeSceneConfigurator.install()`. We can't auto-register from
   Swift (Apple forbids overriding `+load` / `+initialize` in Swift),
   and we can't patch Tauri's `AppDelegate.swift` because Tauri 2.0
   *doesn't generate one* — its app delegate is set up from Rust. The
   `.m` file's `+load` is the one mechanism that runs early, reliably,
   without cooperation from Tauri's launch code.

The Info.plist additions get merged in by
`scripts/apply-ios-overrides.mjs`. Both the `.swift` and `.m` files
are dropped into `src-tauri/gen/apple/<product>_iOS/`, where Tauri's
Xcode project's synchronized groups auto-include them. Everything is
idempotent so re-running `tauri ios init` doesn't lose our work.

## Layout

```
.
├── dist/index.html                   # adaptive black/white blank page
├── package.json                      # tauri CLI + helper scripts
├── scripts/
│   └── apply-ios-overrides.mjs       # copies Swift + merges Info.plist
└── src-tauri/
    ├── Cargo.toml
    ├── build.rs
    ├── tauri.conf.json
    ├── src/{main.rs, lib.rs}
    └── ios-overrides/
        ├── NoChromeBootstrap.m               # +load -> install()
        ├── NoChromeSceneConfigurator.swift   # scene-lifecycle tweaks
        └── Info.additions.plist              # keys to merge
```

`src-tauri/gen/` (Tauri's generated Xcode project) is **gitignored**.
Anything we want to live there permanently belongs in
`src-tauri/ios-overrides/`, then gets installed by the script.

## One-time iOS setup

You need a Mac with Xcode 26 (or later) and the iOS 26 SDK installed,
plus `rustup target add aarch64-apple-ios aarch64-apple-ios-sim`.

```bash
npm install
npm run ios:init      # = `tauri ios init` + apply-ios-overrides
```

After that:

```bash
npm run ios:dev       # run on simulator / connected device
npm run ios:build     # build for distribution
```

If you re-run `tauri ios init` (e.g. after a Tauri upgrade), the
overrides directory is left intact — re-apply with:

```bash
npm run ios:overrides
```

## What's in the overrides

### `Info.additions.plist`

| Key | Value | Why |
| --- | --- | --- |
| `UIDesignRequiresCompatibility` | `YES` | iPadOS 26 opt-out switch that keeps the iOS-18 design language. Most likely single source of relief; everything below is belt-and-braces. |
| `UIRequiresFullScreen` | `YES` | Long-standing key that disables iPad multitasking and removes the user-resize affordance. |
| `UIApplicationSupportsMultipleScenes` | `NO` | Single-window app — no surface for the new window controls to attach to. |
| `UIStatusBarHidden` | `YES` | Edge-to-edge presentation. |
| `UIViewControllerBasedStatusBarAppearance` | `NO` | Honor the plist value above. |
| `UISupportedInterfaceOrientations~ipad` | all four | Lock orientations so the system can pick a fully-sized scene without prompting the resize affordance. |

### `NoChromeSceneConfigurator.swift`

Exposes a single `install()` class method, called from the patched
`AppDelegate.swift`. On every `UIWindowScene` it sees (via
`willConnect` / `didActivate` notifications):

- requests a single full geometry via
  `UIWindowScene.GeometryPreferences.iOS()` so the system knows the
  window is unresizable;
- pokes (under `responds(to:)`) `isUserResizable`,
  `prefersStandardWindowControlsVisible`, `prefersFullScreenContent`,
  `isMenuBarHidden`, `prefersMenuBarHidden` — these are speculative
  names matching Apple's WWDC25 nomenclature; whichever one(s) the
  iPadOS 26 SDK actually exposes will take effect, the rest no-op;
- bumps `setNeedsStatusBarAppearanceUpdate` /
  `setNeedsUpdateOfHomeIndicatorAutoHidden` for edge-to-edge.

Logging is sprinkled throughout (`NSLog("[NoChrome] …")`) so a quick
`xcrun simctl spawn booted log stream --predicate 'eventMessage contains "[NoChrome]"'`
(or the iPad's Console app) will tell us which speculative keys
actually exist on the iPadOS 26 SDK.

## How we'll iterate

This is the "kitchen-sink" first pass. The next steps, in rough order:

1. Build to a real iPad running iPadOS 26. Confirm whether the menu
   bar / resize corner appear at all.
2. If both are gone after step 1, **start removing** keys/code one at
   a time to identify the minimal set that actually does the work,
   and update this README.
3. If either is still visible, replace the speculative KVC keys with
   whatever the iPadOS 26 SDK actually exposes (TBD; check
   `UIWindowScene` headers in the installed SDK and Apple docs once
   we have a Mac to look at).
4. Decide whether `UIDesignRequiresCompatibility = YES` is acceptable
   long-term — it locks the app out of the new design language, which
   may or may not be what we want depending on how much we end up
   relying on Liquid-Glass styling.

The frontend (`dist/index.html`) deliberately stays trivial so the
viewport diagnostic stays clean. Anything visible on screen besides
flat black or flat white is something the OS is drawing.
