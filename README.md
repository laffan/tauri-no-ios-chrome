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
> the first pass, so we now also swizzle
> `UIViewController.prefersStatusBarHidden -> true` and flip
> `UIViewControllerBasedStatusBarAppearance` to YES. Whether the new
> iPadOS 26 menu bar / resize corner are gone is still pending real-
> device confirmation; the speculative KVC pokes will print
> `[NoChrome] set <key> = <value>` for each property that actually
> exists on the SDK's `UIWindowScene`, viewable via the iPad's
> Console app or `log stream --predicate 'eventMessage contains "[NoChrome]"'`
> from a Mac. The README is the running log; expect it to change.
>
> **Icons:** `src-tauri/icons/` contains solid-black PNG placeholders
> (Tauri's `generate_context!` macro fails the build if any referenced
> icon is missing). Replace with real artwork when ready, or run
> `npm run tauri -- icon path/to/source.png` to regenerate the full
> set.

## Strategy, in one paragraph

iPadOS 26 introduced two new always-on-top UI elements (a system menu
bar, a resize corner) as part of its new windowing model. The OS
suppresses both for apps that opt out of the new model. Apple has not
shipped one canonical "hide everything" switch, so we stack the levers
that exist:

1. **`Info.plist` keys** that opt the app out of the new windowing UI
   entirely. The most likely silver bullet is
   `UIDesignRequiresCompatibility = YES`, which keeps the app on the
   iOS 18 design language. We back it up with `UIRequiresFullScreen`
   and `UIApplicationSupportsMultipleScenes = NO`.
2. **A Swift bridge** — `NoChromeSceneConfigurator.swift` — exposes a
   single `install()` static method. It registers
   `UIScene.willConnectNotification` / `didActivateNotification`
   observers and, on every `UIWindowScene`, locks the geometry via
   `UIWindowScene.GeometryPreferences.iOS()` and KVC-pokes every
   plausible "hide-the-chrome" property (`isUserResizable`,
   `prefersFullScreenContent`, `prefersMenuBarHidden`, …) under
   `responds(to:)` guards so the file compiles against any SDK.

`install()` is called from a single line we inject into Tauri's
generated `AppDelegate.swift` (top of
`application(_:didFinishLaunchingWithOptions:)`). We can't auto-
register at load time because Swift forbids overriding `+load` /
`+initialize`; the AppDelegate hook is the next earliest point that
still beats the first scene connection. The injection is performed
by `scripts/apply-ios-overrides.mjs` and is idempotent (guarded by
`// BEGIN NoChrome` markers).

The Info.plist additions get merged in by the same script.
Everything is idempotent so re-running `tauri ios init` doesn't
lose our work.

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
