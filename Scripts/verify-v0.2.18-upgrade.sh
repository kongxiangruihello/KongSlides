#!/usr/bin/env bash
set -euo pipefail

root="$(mktemp -d)"
root="$(cd "$root" && pwd -P)"
helper_pid=""
active_app=""
cleanup() {
    status=$?
    if [[ "$status" != 0 ]]; then
        echo "Desktop check failed (status $status)" >&2
        find "$root" -maxdepth 3 -name '*.app' -print >&2
        ps -ax -o pid,command | grep -E 'KongSlides.app/Contents/(MacOS|Helpers)' >&2 || true
    fi
    if [[ -n "$helper_pid" ]]; then kill "$helper_pid" 2>/dev/null || true; fi
    if [[ -n "$active_app" ]]; then "$root/probe" "$active_app" quit >/dev/null 2>&1 || true; fi
    chmod u+w "$root/read-only" 2>/dev/null || true
    rm -rf "$root"
}
trap cleanup EXIT

gh release download v0.2.17 --pattern KongSlides-0.2.17-macOS-preview.zip --dir "$root"
printf '%s  %s\n' 600a4c38d91ea8f442daa1e67c163afa29e66b27953789e9762c9f9229757139 \
    "$root/KongSlides-0.2.17-macOS-preview.zip" | shasum -a 256 -c
ditto -x -k "$root/KongSlides-0.2.17-macOS-preview.zip" "$root/old"
ditto -x -k "$1" "$root/new"
codesign --verify --deep --strict "$root/old/KongSlides.app"
codesign --verify --deep --strict "$root/new/KongSlides.app"

cat > "$root/probe.swift" <<'SWIFT'
import AppKit
import CoreGraphics
import Foundation

let url = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath().path
guard let app = NSWorkspace.shared.runningApplications.first(where: {
    $0.bundleIdentifier == "com.kongslides.app" && $0.bundleURL?.resolvingSymlinksInPath().path == url && !$0.isTerminated && $0.isFinishedLaunching
}) else { exit(1) }
if CommandLine.arguments.count > 2 {
    if CommandLine.arguments[2] == "quit" { exit(app.terminate() ? 0 : 2) }
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] ?? []
    let ids = windows.compactMap { window -> NSNumber? in
        guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier,
              (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
              let bounds = window[kCGWindowBounds as String] as? [String: NSNumber],
              (bounds["Width"]?.intValue ?? 0) >= 900, (bounds["Height"]?.intValue ?? 0) >= 500
        else { return nil }
        return window[kCGWindowNumber as String] as? NSNumber
    }
    guard ids.count == 1, let id = ids.first else { exit(3) }
    print(id)
    exit(0)
}
print(app.processIdentifier)
SWIFT
swiftc "$root/probe.swift" -o "$root/probe"
cat > "$root/Existing.kongslides" <<'JSON'
{"schemaVersion":1,"slides":[{"id":"4BF6459E-819C-440E-A535-29DE239F51B1","section":"课堂测试","background":"F8F5EE","speakerNotes":"旧版课件讲稿","objects":[]}],"images":[]}
JSON
fixture_checksum="$(shasum -a 256 "$root/Existing.kongslides")"
cp "$root/Existing.kongslides" "$root/Second.kongslides"
cat > "$root/Mouse.kongslides" <<'JSON'
{"schemaVersion":1,"slides":[{"id":"C1795999-C64C-4109-B7A3-851529905CE1","section":"测试第一章","background":"F8F5EE","speakerNotes":"讲稿 1","objects":[]},{"id":"C1795999-C64C-4109-B7A3-851529905CE2","section":"测试第一章","background":"F8F5EE","speakerNotes":"讲稿 2","objects":[]},{"id":"C1795999-C64C-4109-B7A3-851529905CE3","section":"测试第一章","background":"F8F5EE","speakerNotes":"KS-SEARCH-PAGE-3","objects":[]},{"id":"C1795999-C64C-4109-B7A3-851529905CE4","section":"测试第一章","background":"F8F5EE","speakerNotes":"讲稿 4","objects":[]},{"id":"C1795999-C64C-4109-B7A3-851529905CE5","section":"测试第一章","background":"F8F5EE","speakerNotes":"讲稿 5","objects":[]},{"id":"C1795999-C64C-4109-B7A3-851529905CE6","section":"测试第一章","background":"F8F5EE","speakerNotes":"讲稿 6","objects":[]},{"id":"C1795999-C64C-4109-B7A3-851529905CE7","section":"测试第一章","background":"F8F5EE","speakerNotes":"讲稿 7","objects":[]},{"id":"C1795999-C64C-4109-B7A3-851529905CE8","section":"测试第一章","background":"F8F5EE","speakerNotes":"讲稿 8","objects":[]},{"id":"C1795999-C64C-4109-B7A3-851529905CE9","section":"测试第一章","background":"F8F5EE","speakerNotes":"讲稿 9","objects":[]},{"id":"C1795999-C64C-4109-B7A3-851529905CEA","section":"测试第一章","background":"F8F5EE","speakerNotes":"讲稿 10","objects":[]},{"id":"C1795999-C64C-4109-B7A3-851529905CEB","section":"测试第一章","background":"F8F5EE","speakerNotes":"讲稿 11","objects":[]},{"id":"C1795999-C64C-4109-B7A3-851529905CEC","section":"测试第一章","background":"F8F5EE","speakerNotes":"讲稿 12","objects":[]},{"id":"C1795999-C64C-4109-B7A3-851529905CED","section":"测试第一章","background":"F8F5EE","speakerNotes":"讲稿 13","objects":[]},{"id":"C1795999-C64C-4109-B7A3-851529905CEE","section":"测试第一章","background":"F8F5EE","speakerNotes":"讲稿 14","objects":[]},{"id":"C1795999-C64C-4109-B7A3-851529905CEF","section":"测试第一章","background":"F8F5EE","speakerNotes":"讲稿 15","objects":[]},{"id":"C1795999-C64C-4109-B7A3-851529905CF0","section":"测试第二章","background":"F8F5EE","speakerNotes":"讲稿 16","objects":[]},{"id":"C1795999-C64C-4109-B7A3-851529905CF1","section":"测试第二章","background":"F8F5EE","speakerNotes":"讲稿 17","objects":[]},{"id":"C1795999-C64C-4109-B7A3-851529905CF2","section":"测试第二章","background":"F8F5EE","speakerNotes":"讲稿 18","objects":[]},{"id":"C1795999-C64C-4109-B7A3-851529905CF3","section":"测试第二章","background":"F8F5EE","speakerNotes":"讲稿 19","objects":[]},{"id":"C1795999-C64C-4109-B7A3-851529905CF4","section":"测试第二章","background":"F8F5EE","speakerNotes":"讲稿 20","objects":[]},{"id":"C1795999-C64C-4109-B7A3-851529905CF5","section":"测试第二章","background":"F8F5EE","speakerNotes":"讲稿 21","objects":[]},{"id":"C1795999-C64C-4109-B7A3-851529905CF6","section":"测试第二章","background":"F8F5EE","speakerNotes":"讲稿 22","objects":[]},{"id":"C1795999-C64C-4109-B7A3-851529905CF7","section":"测试第二章","background":"F8F5EE","speakerNotes":"讲稿 23","objects":[]},{"id":"C1795999-C64C-4109-B7A3-851529905CF8","section":"测试第二章","background":"F8F5EE","speakerNotes":"讲稿 24","objects":[]},{"id":"C1795999-C64C-4109-B7A3-851529905CF9","section":"测试第二章","background":"F8F5EE","speakerNotes":"讲稿 25","objects":[]},{"id":"C1795999-C64C-4109-B7A3-851529905CFA","section":"测试第二章","background":"F8F5EE","speakerNotes":"讲稿 26","objects":[]},{"id":"C1795999-C64C-4109-B7A3-851529905CFB","section":"测试第二章","background":"F8F5EE","speakerNotes":"讲稿 27","objects":[]},{"id":"C1795999-C64C-4109-B7A3-851529905CFC","section":"测试第二章","background":"F8F5EE","speakerNotes":"讲稿 28","objects":[]},{"id":"C1795999-C64C-4109-B7A3-851529905CFD","section":"测试第二章","background":"F8F5EE","speakerNotes":"讲稿 29","objects":[]},{"id":"C1795999-C64C-4109-B7A3-851529905CFE","section":"测试第二章","background":"F8F5EE","speakerNotes":"讲稿 30","objects":[]}],"images":[]}
JSON
swiftc Scripts/verify-v0.2.18-mouse.swift -o "$root/mouse"

wait_for_app() {
    local running
    for _ in {1..35}; do
        if running="$("$root/probe" "$1")" && [[ "$running" != "${2:-}" ]]; then
            printf '%s\n' "$running"
            return 0
        fi
        sleep 1
    done
    return 1
}

upgrade() {
    local mode="$1" source="$2" target="$3" expected="$4" work pid next updater
    mkdir -p "$(dirname "$source")" "$(dirname "$target")"
    ditto "$root/old/KongSlides.app" "$source"
    echo "Starting desktop check: $mode"
    open -n -F "$source"
    active_app="$source"
    pid="$(wait_for_app "$source")"
    [[ "$pid" =~ ^[0-9]+$ ]]
    echo "Source is running (PID $pid)"
    open -a "$source" "$root/Existing.kongslides"
    if [[ "$mode" == alternate ]]; then
        chmod a-w "$(dirname "$source")"
        [[ ! -w "$(dirname "$source")" ]]
    fi

    work="$(dirname "$target")/.KongSlides-update-$(uuidgen)"
    mkdir -m 700 "$work"
    ditto "$root/new/KongSlides.app" "$work/KongSlides.app"
    updater="$source/Contents/Helpers/KongSlidesUpdater"
    "$updater" "$pid" "$source" "$work" 0.2.18 "$target" "$expected" --show-progress &
    helper_pid=$!
    "$root/probe" "$source" quit

    echo "Source accepted quit; waiting for the updater to relaunch the destination."
    if ! next="$(wait_for_app "$target" "$pid")"; then
        if ! kill -0 "$helper_pid" 2>/dev/null; then
            status=0
            wait "$helper_pid" || status=$?
            echo "Updater exit status: $status"
        fi
        return 1
    fi
    [[ "$next" =~ ^[0-9]+$ && "$next" != "$pid" ]]
    active_app="$target"
    [[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$target/Contents/Info.plist")" == 0.2.18 ]]
    if [[ "$mode" == alternate ]]; then
        [[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$source/Contents/Info.plist")" == 0.2.17 ]]
    fi
    wait "$helper_pid"
    helper_pid=""
    codesign --verify --deep --strict "$target"
    local window_id=""
    for _ in {1..15}; do
        if window_id="$("$root/probe" "$target" editor-window)"; then break; fi
        sleep 1
    done
    [[ "$window_id" =~ ^[0-9]+$ ]]
    if [[ "$mode" == in-place ]]; then
        home_result=0
        "$root/mouse" "$next" --home || home_result=$?
        if [[ "$home_result" != 0 && "$home_result" != 77 ]]; then return "$home_result"; fi
    fi
    open -a "$target" "$root/Existing.kongslides"
    sleep 1
    open -a "$target" "$root/Second.kongslides"
    sleep 1
    [[ "$("$root/probe" "$target" editor-window)" == "$window_id" ]]
    echo "Desktop file opens reused editor window $window_id ($mode)"
    if [[ "$mode" == in-place ]]; then
        home_result=0
        "$root/mouse" "$next" --home-roundtrip || home_result=$?
        if [[ "$home_result" != 0 && "$home_result" != 77 ]]; then return "$home_result"; fi
    fi
    [[ "$(shasum -a 256 "$root/Existing.kongslides")" == "$fixture_checksum" ]]
    if [[ "$mode" == in-place ]]; then
        open -a "$target" "$root/Mouse.kongslides"
        mouse_result=0
        "$root/mouse" "$next" C1795999-C64C-4109-B7A3-851529905CE1 C1795999-C64C-4109-B7A3-851529905CE2 C1795999-C64C-4109-B7A3-851529905CE3 C1795999-C64C-4109-B7A3-851529905CEC C1795999-C64C-4109-B7A3-851529905CF0 || mouse_result=$?
        if [[ "$mouse_result" != 0 && "$mouse_result" != 77 ]]; then return "$mouse_result"; fi
    fi
    "$root/probe" "$target" quit
    for _ in {1..20}; do
        if ! "$root/probe" "$target" >/dev/null; then break; fi
        sleep 1
    done
    if "$root/probe" "$target" >/dev/null; then return 1; fi
    active_app=""
    echo "Desktop upgrade passed: $mode (v0.2.17 to v0.2.18)"
}

upgrade in-place "$root/in-place/KongSlides.app" "$root/in-place/KongSlides.app" 0.2.17
upgrade alternate "$root/read-only/KongSlides.app" "$root/writable/KongSlides.app" ""
