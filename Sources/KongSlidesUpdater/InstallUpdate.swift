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
        guard args.count == 6 || (args.count == 7 && args[6] == "--show-progress"), let pid = pid_t(args[0]), pid > 1,
              let requested = AppVersion(args[3]) else { return }

        let source = URL(fileURLWithPath: args[1], isDirectory: true).standardizedFileURL
        let directory = URL(fileURLWithPath: args[2], isDirectory: true).standardizedFileURL
        let destination = URL(fileURLWithPath: args[4], isDirectory: true).standardizedFileURL
        let candidate = directory.appendingPathComponent("KongSlides.app", isDirectory: true)
        let expected = AppVersion(args[5])
        let prefix = UpdateInstallation.stagePrefix
        guard args[5].isEmpty || expected != nil,
              UpdateInstallation.parentDirectory(of: directory).path ==
                UpdateInstallation.parentDirectory(of: destination).path,
              directory.lastPathComponent.hasPrefix(prefix),
              UUID(uuidString: String(directory.lastPathComponent.dropFirst(prefix.count))) != nil,
              (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
              source.pathExtension == "app", destination.pathExtension == "app",
              source.path == destination.path || destination.lastPathComponent == "KongSlides.app",
              expected.map({ $0 < requested }) ?? true else { return }

        if args.count == 6 {
            if let error = install(pid: pid, source: source, directory: directory, destination: destination,
                                   candidate: candidate, requested: requested, expected: expected, phase: { _ in }) {
                report(error)
            }
            return
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let progress = UpdateProgressPanel(title: "安装 KongSlides \(requested)")
        progress.show("正在等待旧版退出…")
        DispatchQueue.global(qos: .userInitiated).async {
            let error = install(pid: pid, source: source, directory: directory, destination: destination,
                                candidate: candidate, requested: requested, expected: expected) { phase in
                DispatchQueue.main.async { progress.show(phase) }
            }
            DispatchQueue.main.async {
                progress.dismiss()
                if let error { report(error) }
                app.terminate(nil)
            }
        }
        app.run()
    }

    private static func install(pid: pid_t, source: URL, directory: URL, destination: URL,
                                candidate: URL, requested: AppVersion, expected: AppVersion?,
                                phase: (String) -> Void) -> String? {
        let files = FileManager.default
        guard let lock = makeInstallLock(destination) else {
            try? files.removeItem(at: directory)
            return "无法取得更新锁，可能有另一个更新正在安装。"
        }
        defer { close(lock) }
        guard waitForExit(pid) else {
            try? files.removeItem(at: directory)
            return "应用仍在运行，本次更新已取消。请在菜单中重新检查更新。"
        }

        phase("正在校验新版…")
        do {
            guard UpdateInstallation.version(of: candidate) == requested,
                  try UpdateInstallation.runSystemTool("/usr/bin/codesign",
                      arguments: ["--verify", "--strict", "--deep", candidate.path]) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            phase("正在替换应用…")
            try UpdateInstallation.install(candidate, at: destination, replacing: expected)
        } catch {
            try? files.removeItem(at: directory)
            _ = launchApp(source)
            return "无法在所选位置安装。该位置可能已被占用、发生变化或不可写。请重新检查更新。"
        }

        phase("正在打开新版…")
        if launchApp(destination) {
            try? files.removeItem(at: directory)
            return nil
        }
        phase("正在恢复旧版…")
        do {
            if expected == nil {
                try UpdateInstallation.placeExclusively(destination, at: candidate)
            } else {
                try UpdateInstallation.swap(destination, candidate)
            }
            try? files.removeItem(at: directory)
            _ = launchApp(source)
            return "新版未能重新打开，已撤销本次安装。"
        } catch {
            let detail = expected == nil ? "请在 Finder 中核对 \(destination.path)。" : "旧版保留在 \(candidate.path)。"
            return "新版未能重新打开。\(detail)"
        }
    }
}
