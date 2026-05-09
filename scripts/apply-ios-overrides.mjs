#!/usr/bin/env node
//
// Applies the files in `src-tauri/ios-overrides/` to Tauri's generated iOS
// Xcode project at `src-tauri/gen/apple/`. Idempotent: re-running after
// another `tauri ios init` re-installs the overrides cleanly.
//
//   1. Remove obsolete override files left by older versions of this repo.
//   2. Copy each `*.swift` from ios-overrides/ into the iOS sources dir.
//      Files dropped into that dir get picked up by Tauri's Xcode project
//      automatically because the project uses Xcode 15+ synchronized
//      groups.
//   3. Patch the generated `AppDelegate.swift` to call
//      `NoChromeSceneConfigurator.install()` at the top of
//      `application(_:didFinishLaunchingWithOptions:)`. Swift forbids
//      overriding `+load`, so we hook in via the AppDelegate instead.
//   4. Merge every key in `Info.additions.plist` into the generated
//      `Info.plist` via `plutil`.
//
// Run from the repo root:
//     node scripts/apply-ios-overrides.mjs

import { execFileSync } from "node:child_process";
import {
    copyFileSync,
    existsSync,
    readFileSync,
    readdirSync,
    rmSync,
    writeFileSync,
} from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(__dirname, "..");
const overridesDir = join(repoRoot, "src-tauri", "ios-overrides");
const appleGenDir = join(repoRoot, "src-tauri", "gen", "apple");

if (!existsSync(appleGenDir)) {
    console.error(
        `[apply-ios-overrides] ${appleGenDir} not found.\n` +
        `Run \`tauri ios init\` first to generate the iOS Xcode project.`
    );
    process.exit(1);
}

// Find the iOS sources directory. Tauri names it `<product>_iOS`.
const iosSourcesDir = readdirSync(appleGenDir, { withFileTypes: true })
    .filter((d) => d.isDirectory() && d.name.endsWith("_iOS"))
    .map((d) => join(appleGenDir, d.name))[0];

if (!iosSourcesDir) {
    console.error(`[apply-ios-overrides] no <product>_iOS directory under ${appleGenDir}`);
    process.exit(1);
}

// 1. Remove obsolete override files (kept here so older checkouts get cleaned up).
const obsolete = ["AppDelegate+NoChrome.swift"];
for (const name of obsolete) {
    const path = join(iosSourcesDir, name);
    if (existsSync(path)) {
        rmSync(path);
        console.log(`[apply-ios-overrides] removed obsolete ${name}`);
    }
}

// 2. Copy current Swift overrides.
for (const entry of readdirSync(overridesDir)) {
    if (!entry.endsWith(".swift")) continue;
    const src = join(overridesDir, entry);
    const dst = join(iosSourcesDir, entry);
    copyFileSync(src, dst);
    console.log(`[apply-ios-overrides] copied ${entry} -> ${dst}`);
}

// 3. Patch AppDelegate.swift to call NoChromeSceneConfigurator.install().
const appDelegate = join(iosSourcesDir, "AppDelegate.swift");
if (!existsSync(appDelegate)) {
    console.error(`[apply-ios-overrides] ${appDelegate} not found`);
    process.exit(1);
}

const PATCH_BEGIN = "// BEGIN NoChrome";
const PATCH_END = "// END NoChrome";
const PATCH_BODY = [
    "        " + PATCH_BEGIN,
    "        NoChromeSceneConfigurator.install()",
    "        " + PATCH_END,
].join("\n");

let appDelegateSrc = readFileSync(appDelegate, "utf8");
if (appDelegateSrc.includes(PATCH_BEGIN)) {
    console.log("[apply-ios-overrides] AppDelegate.swift already patched, skipping");
} else {
    // Find the opening `{` of `application(_:didFinishLaunchingWithOptions:)`.
    // Permissive regex: tolerate any whitespace / argument formatting.
    const sigRe = /func\s+application\s*\([^{]*?didFinishLaunchingWithOptions[^{]*?\)\s*->\s*Bool\s*\{/s;
    const m = appDelegateSrc.match(sigRe);
    if (!m) {
        console.error(
            "[apply-ios-overrides] could not locate application(_:didFinishLaunchingWithOptions:) " +
            `in ${appDelegate}. Patch manually: add NoChromeSceneConfigurator.install() ` +
            "to the top of that method."
        );
        process.exit(1);
    }
    const insertAt = m.index + m[0].length;
    appDelegateSrc =
        appDelegateSrc.slice(0, insertAt) +
        "\n" + PATCH_BODY +
        appDelegateSrc.slice(insertAt);
    writeFileSync(appDelegate, appDelegateSrc);
    console.log(`[apply-ios-overrides] patched ${appDelegate}`);
}

// 4. Merge Info.plist additions via plutil JSON round-trip.
const additionsPlist = join(overridesDir, "Info.additions.plist");
const infoPlist = join(iosSourcesDir, "Info.plist");
if (!existsSync(infoPlist)) {
    console.error(`[apply-ios-overrides] ${infoPlist} not found`);
    process.exit(1);
}

const additionsJson = execFileSync(
    "plutil",
    ["-convert", "json", "-o", "-", additionsPlist],
    { encoding: "utf8" }
);
const additions = JSON.parse(additionsJson);

for (const [key, value] of Object.entries(additions)) {
    const valueJson = JSON.stringify(value);
    try {
        execFileSync("plutil", [
            "-replace", key,
            "-json", valueJson,
            infoPlist,
        ], { stdio: ["ignore", "ignore", "inherit"] });
    } catch {
        execFileSync("plutil", [
            "-insert", key,
            "-json", valueJson,
            infoPlist,
        ], { stdio: ["ignore", "ignore", "inherit"] });
    }
    console.log(`[apply-ios-overrides] merged Info.plist key ${key}`);
}

console.log("[apply-ios-overrides] done.");
