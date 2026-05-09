#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    tauri_no_ios_chrome_lib::run()
}
