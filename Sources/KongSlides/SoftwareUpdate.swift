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
        RecoverySession.shared.finish()
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
            let progress = UpdateProgressPanel(title: "KongSlides 软件更新")
            let files = FileManager.default
            let downloadFolder = files.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try files.createDirectory(at: downloadFolder, withIntermediateDirectories: false,
                                      attributes: [.posixPermissions: 0o700])
            defer { try? files.removeItem(at: downloadFolder) }
            let downloaded = downloadFolder.appendingPathComponent("update.zip")
            progress.show("正在下载更新…", fraction: 0)
            defer { progress.dismiss() }
            try await download(offer, to: downloaded, panel: progress)
            progress.show("正在校验安装包…")

            let app = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
            let update: StagedUpdate
            do {
                update = try await prepare(downloaded, offer: offer, source: app, destination: app,
                                           expected: version)
            } catch UpdateProblem.appLocation {
                progress.dismiss()
                guard let destination = chooseDestination(for: offer.version) else { return }
                guard destination.path != app.path else { throw UpdateProblem.appLocation }
                let existing = try StagedUpdate.versionAtDestination(destination)
                if let existing, existing >= offer.version { throw UpdateProblem.destinationOccupied }
                progress.show("正在准备安装…")
                update = try await prepare(downloaded, offer: offer, source: app,
                                           destination: destination, expected: existing)
            }
            progress.dismiss()
            staged = update
            offerInstallation(update)
        } catch {
            if manual || didPromptForDownload {
                show("更新未完成", detail: error.localizedDescription, releasePage: true)
            }
        }
        #endif
    }

    private func download(_ offer: UpdateOffer, to destination: URL, panel: UpdateProgressPanel) async throws {
        let status = Progress(totalUnitCount: Int64(offer.bytes))
        let task = Task { @MainActor in
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let request = URLRequest(url: offer.downloadURL, timeoutInterval: 60)
                let download = session.downloadTask(with: request) { url, response, error in
                    do {
                        if let error { throw error }
                        guard let url, (response as? HTTPURLResponse)?.statusCode == 200 else {
                            throw UpdateProblem.connection
                        }
                        try FileManager.default.moveItem(at: url, to: destination)
                        continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
                status.addChild(download.progress, withPendingUnitCount: status.totalUnitCount)
                download.resume()
            }
        }
        let monitor = Task { @MainActor in
            while !Task.isCancelled {
                if status.totalUnitCount > 0 {
                    let fraction = min(1, max(0, status.fractionCompleted))
                    panel.show("正在下载更新… \(Int(fraction * 100))%", fraction: fraction)
                }
                try await Task.sleep(for: .milliseconds(150))
            }
        }
        defer { monitor.cancel() }
        try await task.value
    }

    private func prepare(_ archive: URL, offer: UpdateOffer, source: URL,
                         destination: URL, expected: AppVersion?) async throws -> StagedUpdate {
        try await Task.detached(priority: .userInitiated) {
            try StagedUpdate.prepare(archive: archive, offer: offer, source: source,
                                     destination: destination, expected: expected)
        }.value
    }

    private func chooseDestination(for version: AppVersion) -> URL? {
        let prompt = NSAlert()
        prompt.messageText = "请选择新版的安装位置"
        prompt.informativeText = "当前运行位置无法原位更新。您可以把已下载的 KongSlides \(version) 安装到可写的文件夹。"
        prompt.addButton(withTitle: "选择文件夹…")
        prompt.addButton(withTitle: "稍后")
        guard prompt.runModal() == .alertFirstButtonReturn else { return nil }

        let files = FileManager.default
        let personalApplications = files.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        let panel = NSOpenPanel()
        panel.message = "请选择安装 KongSlides.app 的文件夹。"
        panel.prompt = "选为安装位置"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = files.fileExists(atPath: personalApplications.path)
            ? personalApplications : files.homeDirectoryForCurrentUser
        guard panel.runModal() == .OK, let folder = panel.url else { return nil }
        return folder.resolvingSymlinksInPath().standardizedFileURL
            .appendingPathComponent("KongSlides.app", isDirectory: true)
    }

    private func offerInstallation(_ update: StagedUpdate) {
        let prompt = NSAlert()
        prompt.messageText = "KongSlides \(update.version) 已准备好"
        if update.source.path == update.destination.path {
            prompt.informativeText = "应用将按正常流程关闭，未保存的课件会先提示处理。随后安装新版并重新打开。"
        } else {
            let operation = update.expected == nil ? "安装到" : "替换"
            prompt.informativeText = "应用将先按正常流程关闭，然后\(operation) \(update.destination.path) 并打开新版。"
        }
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
        let helper = staged.source.appendingPathComponent("Contents/Helpers/KongSlidesUpdater")
        let process = Process()
        process.executableURL = helper
        process.arguments = [
            String(ProcessInfo.processInfo.processIdentifier), staged.source.path,
            staged.directory.path, staged.version.description, staged.destination.path,
            staged.expected?.description ?? "", "--show-progress"
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
    case destinationOccupied

    var errorDescription: String? {
        switch self {
        case .connection: "暂时无法从 GitHub 获取更新。请稍后重试。"
        case .verification: "安装包未通过校验，当前应用没有被替换。"
        case .appLocation: "这个文件夹无法安装 KongSlides。请在检查更新时选择一个可写的文件夹。"
        case .destinationOccupied: "所选位置已被占用，或已有同版或更高版本的 KongSlides。请打开已有版本，或选择其他文件夹。"
        }
    }
}

private struct StagedUpdate: Sendable {
    let source: URL
    let destination: URL
    let expected: AppVersion?
    let directory: URL
    let version: AppVersion
    var installAuthorized = false

    static func versionAtDestination(_ destination: URL) throws -> AppVersion? {
        do {
            return try UpdateInstallation.installedVersion(at: destination)
        } catch let issue as CocoaError where issue.code == .fileWriteFileExists {
            throw UpdateProblem.destinationOccupied
        } catch {
            throw UpdateProblem.appLocation
        }
    }

    static func prepare(archive: URL, offer: UpdateOffer, source: URL,
                        destination: URL, expected: AppVersion?) throws -> Self {
        guard try UpdateRepository.isMatchingArchive(archive, bytes: offer.bytes, sha256: offer.sha256) else {
            throw UpdateProblem.verification
        }
        guard !destination.path.contains("/AppTranslocation/"), destination.pathExtension == "app" else {
            throw UpdateProblem.appLocation
        }
        do {
            guard try versionAtDestination(destination) == expected else { throw UpdateProblem.destinationOccupied }
        } catch where source.path == destination.path {
            throw UpdateProblem.appLocation
        }
        let directory = UpdateInstallation.parentDirectory(of: destination)
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
            return Self(source: source, destination: destination, expected: expected,
                        directory: directory, version: offer.version)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}
