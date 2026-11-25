import AppKit
import Foundation
import KongSlidesUpdateSupport

@MainActor
final class AppLifecycle: NSObject, NSApplicationDelegate {
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            await SoftwareUpdate.shared.check(manual: false)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { _ in
            Task { @MainActor in await SoftwareUpdate.shared.check(manual: false) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        SoftwareUpdate.shared.finishQuitting()
    }
}

@MainActor
final class SoftwareUpdate {
    static let shared = SoftwareUpdate()
    nonisolated static let automaticKey = "checkForUpdatesAutomatically"
    private static let lastCheckKey = "lastSoftwareUpdateCheck"
    private let session = URLSession(configuration: .ephemeral, delegate: GitHubRedirects(), delegateQueue: nil)
    private var busy = false
    private var staged: StagedUpdate?

    func check(manual: Bool) async {
        guard !busy else { return }
        if let staged {
            if manual { offerInstallation(staged) }
            return
        }
        guard let versionString = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let version = AppVersion(versionString) else { return }

        #if !arch(arm64)
        if manual {
            show("此 Mac 请从发布页获取更新", detail: "当前自动安装包适用于 Apple 芯片。",
                 releasePage: true)
        }
        return
        #else
        let preferences = UserDefaults.standard
        let last = preferences.object(forKey: Self.lastCheckKey) as? Date
        if !manual {
            let enabled = preferences.object(forKey: Self.automaticKey) as? Bool ?? true
            let elapsed = last.map { Date().timeIntervalSince($0) } ?? .infinity
            guard enabled, NSApp.isActive, elapsed < 0 || elapsed >= 24 * 60 * 60 else { return }
        }

        busy = true
        var didPromptForDownload = false
        defer { busy = false }
        do {
            var request = URLRequest(url: UpdateRepository.apiURL, timeoutInterval: 20)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("KongSlides/\(version)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateProblem.connection }
            let offer = try UpdateRepository.findUpdate(in: data, current: version)
            guard manual || offer == nil || NSApp.isActive else { return }
            preferences.set(Date(), forKey: Self.lastCheckKey)
            guard let offer else {
                if manual { show("KongSlides 已是最新版", detail: "当前版本 \(version)") }
                return
            }
            let prompt = NSAlert()
            prompt.messageText = "KongSlides \(offer.version) 可更新"
            prompt.informativeText = "当前版本 \(version)。下载后会先校验安装包，您可以选在方便时退出并安装。"
            prompt.addButton(withTitle: "下载更新")
            prompt.addButton(withTitle: "稍后")
            guard prompt.runModal() == .alertFirstButtonReturn else { return }

            didPromptForDownload = true
            let (archive, download) = try await session.download(for: URLRequest(url: offer.downloadURL,
                                                                                 timeoutInterval: 60))
            defer { try? FileManager.default.removeItem(at: archive) }
            guard (download as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateProblem.connection }

            let files = FileManager.default
            let downloadFolder = files.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try files.createDirectory(at: downloadFolder, withIntermediateDirectories: false,
                                      attributes: [.posixPermissions: 0o700])
            defer { try? files.removeItem(at: downloadFolder) }
            let downloaded = downloadFolder.appendingPathComponent("update.zip")
            try files.moveItem(at: archive, to: downloaded)

            let app = Bundle.main.bundleURL
            let update = try await Task.detached(priority: .userInitiated) {
                try StagedUpdate.prepare(archive: downloaded, offer: offer, current: app, version: version)
            }.value
            staged = update
            offerInstallation(update)
        } catch {
            if manual || didPromptForDownload {
                show("更新未完成", detail: error.localizedDescription, releasePage: true)
            }
        }
        #endif
    }

    private func offerInstallation(_ update: StagedUpdate) {
        let prompt = NSAlert()
        prompt.messageText = "KongSlides \(update.version) 已准备好"
        prompt.informativeText = "应用将按正常流程关闭，未保存的课件会先提示处理。随后安装新版并重新打开。"
        prompt.addButton(withTitle: "退出并安装")
        prompt.addButton(withTitle: "稍后")
        guard prompt.runModal() == .alertFirstButtonReturn else { return }
        staged?.installAuthorized = true
        NSApp.terminate(nil)
    }

    func finishQuitting() {
        guard let staged else { return }
        // The alert authorizes installation only until the next normal quit.
        guard staged.installAuthorized else {
            try? FileManager.default.removeItem(at: staged.directory)
            return
        }
        let helper = staged.current.appendingPathComponent("Contents/Helpers/KongSlidesUpdater")
        let process = Process()
        process.executableURL = helper
        process.arguments = [
            String(ProcessInfo.processInfo.processIdentifier), staged.current.path,
            staged.directory.path, staged.version.description
        ]
        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: staged.directory)
            show("无法启动更新程序", detail: error.localizedDescription, releasePage: true)
        }
    }

    private func show(_ title: String, detail: String, releasePage: Bool = false) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "好")
        if releasePage { alert.addButton(withTitle: "打开发布页") }
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(UpdateRepository.releasesURL)
        }
    }
}

private final class GitHubRedirects: NSObject, URLSessionTaskDelegate {
    private static let hosts: Set<String> = [
        "github.com", "api.github.com", "release-assets.githubusercontent.com",
        "objects.githubusercontent.com", "github-releases.githubusercontent.com"
    ]

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, url.scheme == "https", let host = url.host,
              Self.hosts.contains(host), url.user == nil, url.password == nil, url.port == nil else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

private enum UpdateProblem: LocalizedError {
    case connection
    case verification
    case appLocation

    var errorDescription: String? {
        switch self {
        case .connection: "暂时无法从 GitHub 获取更新。请稍后重试。"
        case .verification: "安装包未通过校验，当前应用没有被替换。"
        case .appLocation: "当前应用所在位置无法写入。请先把 KongSlides 移到可写的文件夹，或从发布页下载安装包。"
        }
    }
}

private struct StagedUpdate: Sendable {
    let current: URL
    let directory: URL
    let version: AppVersion
    var installAuthorized = false

    static func prepare(archive: URL, offer: UpdateOffer, current: URL, version: AppVersion) throws -> Self {
        guard try UpdateRepository.isMatchingArchive(archive, bytes: offer.bytes, sha256: offer.sha256) else {
            throw UpdateProblem.verification
        }
        let app = current.resolvingSymlinksInPath().standardizedFileURL
        guard !app.path.contains("/AppTranslocation/"), app.pathExtension == "app",
              UpdateInstallation.version(of: app) == version else { throw UpdateProblem.appLocation }
        let directory = app.deletingLastPathComponent()
            .appendingPathComponent(UpdateInstallation.stagePrefix + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
        } catch { throw UpdateProblem.appLocation }

        do {
            guard try UpdateInstallation.runSystemTool("/usr/bin/ditto", arguments: ["-x", "-k", archive.path, directory.path]) else {
                throw UpdateProblem.verification
            }
            let candidate = directory.appendingPathComponent("KongSlides.app", isDirectory: true)
            guard UpdateInstallation.version(of: candidate) == offer.version,
                  try UpdateInstallation.runSystemTool("/usr/bin/codesign", arguments: ["--verify", "--strict", "--deep", candidate.path]) else {
                throw UpdateProblem.verification
            }
            return Self(current: app, directory: directory, version: offer.version)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}
