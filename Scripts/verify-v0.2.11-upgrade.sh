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

gh release download v0.2.10 --pattern KongSlides-0.2.10-macOS-preview.zip --dir "$root"
printf '%s  %s\n' cc199df6601ed166a57815706d72fb72f612175b96dd1f43c7c92fd02fe14e47 \
    "$root/KongSlides-0.2.10-macOS-preview.zip" | shasum -a 256 -c
ditto -x -k "$root/KongSlides-0.2.10-macOS-preview.zip" "$root/old"
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
    "$updater" "$pid" "$source" "$work" 0.2.11 "$target" "$expected" --show-progress &
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
    [[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$target/Contents/Info.plist")" == 0.2.11 ]]
    if [[ "$mode" == alternate ]]; then
        [[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$source/Contents/Info.plist")" == 0.2.10 ]]
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
    open -a "$target" "$root/Existing.kongslides"
    sleep 1
    open -a "$target" "$root/Second.kongslides"
    sleep 1
    [[ "$("$root/probe" "$target" editor-window)" == "$window_id" ]]
    echo "Desktop file opens reused editor window $window_id ($mode)"
    [[ "$(shasum -a 256 "$root/Existing.kongslides")" == "$fixture_checksum" ]]
    "$root/probe" "$target" quit
    for _ in {1..20}; do
        if ! "$root/probe" "$target" >/dev/null; then break; fi
        sleep 1
    done
    if "$root/probe" "$target" >/dev/null; then return 1; fi
    active_app=""
    echo "Desktop upgrade passed: $mode (v0.2.10 to v0.2.11)"
}

upgrade in-place "$root/in-place/KongSlides.app" "$root/in-place/KongSlides.app" 0.2.10
upgrade alternate "$root/read-only/KongSlides.app" "$root/writable/KongSlides.app" ""
