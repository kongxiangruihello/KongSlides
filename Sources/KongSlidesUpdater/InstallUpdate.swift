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
        guard args.count == 4, let pid = pid_t(args[0]), pid > 1,
              let requested = AppVersion(args[3]) else { return }

        let current = URL(fileURLWithPath: args[1], isDirectory: true).standardizedFileURL
        let directory = URL(fileURLWithPath: args[2], isDirectory: true).standardizedFileURL
        let candidate = directory.appendingPathComponent("KongSlides.app", isDirectory: true)
        let prefix = UpdateInstallation.stagePrefix
        guard directory.deletingLastPathComponent().path == current.deletingLastPathComponent().path,
              directory.lastPathComponent.hasPrefix(prefix),
              UUID(uuidString: String(directory.lastPathComponent.dropFirst(prefix.count))) != nil,
              directory.resolvingSymlinksInPath().path == directory.path,
              current.pathExtension == "app",
              let old = UpdateInstallation.version(of: current), requested > old else { return }

        guard let lock = makeInstallLock(current) else {
            try? FileManager.default.removeItem(at: directory)
            report("无法取得更新锁，可能有另一个更新正在安装。")
            return
        }
        defer { close(lock) }
        guard waitForExit(pid) else {
            try? FileManager.default.removeItem(at: directory)
            report("应用仍在运行，本次更新已取消。请在菜单中重新检查更新。")
            return
        }

        guard UpdateInstallation.version(of: current) == old,
              UpdateInstallation.version(of: candidate) == requested,
              (try? UpdateInstallation.runSystemTool("/usr/bin/codesign",
                    arguments: ["--verify", "--strict", "--deep", candidate.path])) == true else {
            try? FileManager.default.removeItem(at: directory)
            _ = launchApp(current)
            report("应用或安装包在退出期间发生变化，请重新检查更新。")
            return
        }

        do {
            try UpdateInstallation.swap(current, candidate)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            _ = launchApp(current)
            report("无法替换当前应用。请检查应用所在文件夹的写入权限。")
            return
        }

        if launchApp(current) {
            try? FileManager.default.removeItem(at: directory)
            return
        }
        do {
            try UpdateInstallation.swap(current, candidate)
            try? FileManager.default.removeItem(at: directory)
            _ = launchApp(current)
            report("新版未能重新打开，已恢复旧版。")
        } catch {
            report("新版未能重新打开。旧版仍保存在 \(candidate.path)。")
        }
    }
}
