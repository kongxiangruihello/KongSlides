import AppKit
import CryptoKit
import Darwin
import Foundation
import KongSlidesUpdateSupport

private func waitForExit(_ pid: pid_t) -> Bool {
    if kill(pid, 0) == -1 && errno == ESRCH { return true }
    let exited = DispatchSemaphore(value: 0)
    let watcher = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
    watcher.setEventHandler { exited.signal() }
    watcher.resume()
    defer { watcher.cancel() }
    if kill(pid, 0) == -1 && errno == ESRCH { return true }
    return exited.wait(timeout: .now() + 30) == .success
}

private func makeInstallLock(_ app: URL) -> Int32? {
    let sha = SHA256.hash(data: Data(app.path.utf8)).map { String(format: "%02x", $0) }.joined()
    let lock = FileManager.default.temporaryDirectory.appendingPathComponent("KongSlides-install-" + sha)
    let descriptor = lock.path.withCString { open($0, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600)) }
    guard descriptor >= 0 else { return nil }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
        close(descriptor)
        return nil
    }
    return descriptor
}

private func launchApp(_ app: URL) -> Bool {
    (try? UpdateInstallation.runSystemTool("/usr/bin/open", arguments: ["-n", app.path])) == true
}

@MainActor private func report(_ detail: String) {
    NSApplication.shared.setActivationPolicy(.accessory)
    NSApplication.shared.activate()
    let alert = NSAlert()
    alert.messageText = "KongSlides 更新未完成"
    alert.informativeText = detail
    alert.addButton(withTitle: "好")
    alert.runModal()
}

@main
enum InstallUpdate {
    @MainActor
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 6, let pid = pid_t(args[0]), pid > 1,
              let requested = AppVersion(args[3]) else { return }

        let source = URL(fileURLWithPath: args[1], isDirectory: true).standardizedFileURL
        let directory = URL(fileURLWithPath: args[2], isDirectory: true).standardizedFileURL
        let destination = URL(fileURLWithPath: args[4], isDirectory: true).standardizedFileURL
        let candidate = directory.appendingPathComponent("KongSlides.app", isDirectory: true)
        let expected = AppVersion(args[5])
        let prefix = UpdateInstallation.stagePrefix
        guard args[5].isEmpty || expected != nil,
              directory.deletingLastPathComponent().path == destination.deletingLastPathComponent().path,
              directory.lastPathComponent.hasPrefix(prefix),
              UUID(uuidString: String(directory.lastPathComponent.dropFirst(prefix.count))) != nil,
              directory.resolvingSymlinksInPath().path == directory.path,
              source.pathExtension == "app", destination.pathExtension == "app",
              source.path == destination.path || destination.lastPathComponent == "KongSlides.app",
              expected.map({ $0 < requested }) ?? true else { return }

        let files = FileManager.default
        guard let lock = makeInstallLock(destination) else {
            try? files.removeItem(at: directory)
            report("无法取得更新锁，可能有另一个更新正在安装。")
            return
        }
        defer { close(lock) }
        guard waitForExit(pid) else {
            try? files.removeItem(at: directory)
            report("应用仍在运行，本次更新已取消。请在菜单中重新检查更新。")
            return
        }

        do {
            guard UpdateInstallation.version(of: candidate) == requested,
                  try UpdateInstallation.runSystemTool("/usr/bin/codesign",
                      arguments: ["--verify", "--strict", "--deep", candidate.path]) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try UpdateInstallation.install(candidate, at: destination, replacing: expected)
        } catch {
            try? files.removeItem(at: directory)
            _ = launchApp(source)
            report("无法在所选位置安装。该位置可能已被占用、发生变化或不可写。请重新检查更新。")
            return
        }

        if launchApp(destination) {
            try? files.removeItem(at: directory)
            return
        }
        do {
            if expected == nil {
                try UpdateInstallation.placeExclusively(destination, at: candidate)
            } else {
                try UpdateInstallation.swap(destination, candidate)
            }
            try? files.removeItem(at: directory)
            _ = launchApp(source)
            report("新版未能重新打开，已撤销本次安装。")
        } catch {
            let detail = expected == nil ? "请在 Finder 中核对 \(destination.path)。" : "旧版保留在 \(candidate.path)。"
            report("新版未能重新打开。\(detail)")
        }
    }
}
