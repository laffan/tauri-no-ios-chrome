#!/usr/bin/env node
//
// Applies the files in `src-tauri/ios-overrides/` to Tauri's generated iOS
// Xcode project at `src-tauri/gen/apple/`. Idempotent: re-running after
// another `tauri ios init` re-installs the overrides cleanly.
//
//   1. Remove obsolete override files left by older versions of this repo.
//   2. Copy each `*.swift` and `*.m` from ios-overrides/ into the iOS
//      sources dir. Tauri's Xcode project uses synchronized groups so
//      files dropped there get auto-included in the build.
//   3. Merge every key in `Info.additions.plist` into the generated
//      `Info.plist` via `plutil`.
//
// We do NOT patch AppDelegate.swift — Tauri 2.0 doesn't generate one.
// Bootstrap happens via NoChromeBootstrap.m's +load instead.
//
// Run from the repo root:
//     node scripts/apply-ios-overrides.mjs

import { execFileSync } from "node:child_process";
import {
    copyFileSync,
    existsSync,
    readdirSync,
    rmSync,
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

// 2. Copy current source overrides (Swift + Obj-C).
const sourceExts = [".swift", ".m", ".h"];
let copiedAny = false;
for (const entry of readdirSync(overridesDir)) {
    const lower = entry.toLowerCase();
    if (!sourceExts.some((ext) => lower.endsWith(ext))) continue;
    const src = join(overridesDir, entry);
    const dst = join(iosSourcesDir, entry);
    copyFileSync(src, dst);
    console.log(`[apply-ios-overrides] copied ${entry} -> ${dst}`);
    copiedAny = true;
}
if (!copiedAny) {
    console.error(
        `[apply-ios-overrides] no source overrides found in ${overridesDir} — ` +
        `expected at least one .swift or .m file. Refusing to silently no-op.`
    );
    process.exit(1);
}

// 3. Merge Info.plist additions via plutil JSON round-trip.
const additionsPlist = join(overridesDir, "Info.additions.plist");
const infoPlist = join(iosSourcesDir, "Info.plist");
if (!existsSync(additionsPlist)) {
    console.error(`[apply-ios-overrides] ${additionsPlist} not found`);
    process.exit(1);
}
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
