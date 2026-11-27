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

gh release download v0.2.2 --pattern KongSlides-0.2.2-macOS-preview.zip --dir "$root"
printf '%s  %s\n' b89b94990e63fb9ebf272d748d34df8f8598ccd64741cc2e0f276013c482f82a \
    "$root/KongSlides-0.2.2-macOS-preview.zip" | shasum -a 256 -c
ditto -x -k "$root/KongSlides-0.2.2-macOS-preview.zip" "$root/old"
ditto -x -k "$1" "$root/new"
codesign --verify --deep --strict "$root/old/KongSlides.app"
codesign --verify --deep --strict "$root/new/KongSlides.app"

cat > "$root/probe.swift" <<'SWIFT'
import AppKit
import Foundation

let url = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath().path
guard let app = NSWorkspace.shared.runningApplications.first(where: {
    $0.bundleIdentifier == "com.kongslides.app" && $0.bundleURL?.resolvingSymlinksInPath().path == url && !$0.isTerminated && $0.isFinishedLaunching
}) else { exit(1) }
if CommandLine.arguments.count > 2 {
    exit(app.terminate() ? 0 : 2)
}
print(app.processIdentifier)
SWIFT
swiftc "$root/probe.swift" -o "$root/probe"
cat > "$root/Existing.kongslides" <<'JSON'
{"schemaVersion":1,"slides":[{"id":"4BF6459E-819C-440E-A535-29DE239F51B1","section":"课堂测试","background":"F8F5EE","speakerNotes":"旧版课件讲稿","objects":[]}],"images":[]}
JSON
fixture_checksum="$(shasum -a 256 "$root/Existing.kongslides")"

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
    "$updater" "$pid" "$source" "$work" 0.2.3 "$target" "$expected" --show-progress &
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
    [[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$target/Contents/Info.plist")" == 0.2.3 ]]
    if [[ "$mode" == alternate ]]; then
        [[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$source/Contents/Info.plist")" == 0.2.2 ]]
    fi
    wait "$helper_pid"
    helper_pid=""
    codesign --verify --deep --strict "$target"
    open -a "$target" "$root/Existing.kongslides"
    [[ "$(shasum -a 256 "$root/Existing.kongslides")" == "$fixture_checksum" ]]
    "$root/probe" "$target" quit
    for _ in {1..20}; do
        if ! "$root/probe" "$target" >/dev/null; then break; fi
        sleep 1
    done
    if "$root/probe" "$target" >/dev/null; then return 1; fi
    active_app=""
    echo "Desktop upgrade passed: $mode (v0.2.2 to v0.2.3)"
}

upgrade in-place "$root/in-place/KongSlides.app" "$root/in-place/KongSlides.app" 0.2.2
upgrade alternate "$root/read-only/KongSlides.app" "$root/writable/KongSlides.app" ""
