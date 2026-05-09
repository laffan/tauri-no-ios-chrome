# tauri-no-ios-chrome

A bare-bones Tauri 2.0 app whose only job is to figure out the right
combination of `Info.plist` keys and Swift code needed to hide the new
iPadOS 26 system chrome — the top **menu bar** and the bottom-right
**window resize corner**.

The app itself is a blank page that paints **black in dark mode** and
**white in light mode** (driven by the system's `prefers-color-scheme`).
That makes it easy to verify visually that nothing the OS is drawing
on top of us — bar, divider, corner glyph, status indicator — is showing.

> **Status:** scaffold + first-pass overrides committed. Nothing has
> been validated on a real iPad yet — this is the starting point for
> iteration. The README is the running log; expect it to change.
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
2. **A Swift bridge** — `NoChromeSceneConfigurator.swift` — registered
   in `+load` so it runs before any of Tauri's launch code. It listens
   for `UIScene.willConnect` / `didActivate` notifications and, on each
   connecting `UIWindowScene`, KVC-pokes every plausible
   "hide-the-chrome" property (`isUserResizable`,
   `prefersFullScreenContent`, `prefersMenuBarHidden`, …) under
   `responds(to:)` guards so the file compiles against any SDK.
3. **Menu swizzle** — `AppDelegate+NoChrome.swift` swizzles
   `UIResponder.buildMenu(with:)` so every standard menu identifier
   gets removed. If the new menu bar is content-driven, this collapses
   it to nothing.

We don't fork Tauri's generated `AppDelegate` / `SceneDelegate`. The
overrides live next to them as additional Swift sources in the same
target, plus the Info.plist additions get merged in by a small Node
script. Everything is idempotent so re-running `tauri ios init`
doesn't lose our work.

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
        ├── NoChromeSceneConfigurator.swift   # +load, scene tweaks
        ├── AppDelegate+NoChrome.swift        # buildMenu(with:) swizzle
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

Registers in `+load` for the earliest possible hook. On every
`UIWindowScene` it sees:

- requests a single full geometry via
  `UIWindowScene.GeometryPreferences.iOS()` so the system knows the
  window is unresizable;
- pokes (under `responds(to:)`) `isUserResizable`,
  `prefersStandardWindowControlsVisible`, `prefersFullScreenContent`,
  `isMenuBarHidden`, `prefersMenuBarHidden`, `menuBarVisibility` —
  these are speculative names matching Apple's WWDC25 nomenclature;
  whichever one(s) the iPadOS 26 SDK actually exposes will take
  effect, the rest no-op;
- forces a `UIMenuSystem.main.setNeedsRebuild()` so the swizzle below
  gets a chance to empty the bar.

### `AppDelegate+NoChrome.swift`

Swizzles `UIResponder.buildMenu(with:)` at runtime so every standard
menu identifier (`.application`, `.file`, `.edit`, … `.root`) is
removed before the system displays it. The previous extension-based
attempt couldn't actually override the method — Swift extensions
can't override methods on non-final ObjC classes — so we go through
`class_addMethod` / `method_exchangeImplementations`.

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
