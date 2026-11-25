import CryptoKit
import Darwin
import Foundation

public struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    private let major: Int
    private let minor: Int
    private let patch: Int

    public init?(_ value: String) {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ part in
            !part.isEmpty && part.count <= 9 &&
                (part.count == 1 || part.first != "0") &&
                part.utf8.allSatisfy { (48...57).contains($0) }
        }), let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2]) else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

public struct UpdateOffer: Equatable, Sendable {
    public let version: AppVersion
    public let downloadURL: URL
    public let sha256: String
    public let bytes: Int
}

public enum UpdateRepository {
    public static let bundleID = "com.kongslides.app"
    public static let apiURL = URL(string: "https://api.github.com/repos/kongxiangruihello/KongSlides/releases?per_page=20")!
    public static let releasesURL = URL(string: "https://github.com/kongxiangruihello/KongSlides/releases")!
    public static let maximumBytes = 100 * 1024 * 1024

    private struct Release: Decodable {
        let tag_name: String
        let draft: Bool
        let assets: [Asset]
    }

    private struct Asset: Decodable {
        let name: String
        let state: String
        let browser_download_url: URL
        let digest: String?
        let size: Int
    }

    public static func findUpdate(in data: Data, current: AppVersion) throws -> UpdateOffer? {
        let releases = try JSONDecoder().decode([Release].self, from: data)
        return releases.compactMap { release -> UpdateOffer? in
            guard !release.draft, release.tag_name.first == "v",
                  let version = AppVersion(String(release.tag_name.dropFirst())), version > current else { return nil }
            let name = "KongSlides-\(version)-macOS-preview.zip"
            let path = "/kongxiangruihello/KongSlides/releases/download/v\(version)/\(name)"
            guard let asset = release.assets.first(where: { $0.name == name && $0.state == "uploaded" }),
                  (1...maximumBytes).contains(asset.size),
                  let parts = URLComponents(url: asset.browser_download_url, resolvingAgainstBaseURL: false),
                  parts.scheme == "https", parts.host == "github.com", parts.path == path,
                  parts.user == nil, parts.password == nil, parts.port == nil,
                  parts.query == nil, parts.fragment == nil,
                  let digest = asset.digest, digest.hasPrefix("sha256:") else { return nil }
            let checksum = String(digest.dropFirst("sha256:".count)).lowercased()
            guard checksum.utf8.count == 64,
                  checksum.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
            return UpdateOffer(version: version, downloadURL: asset.browser_download_url,
                               sha256: checksum, bytes: asset.size)
        }.max { $0.version < $1.version }
    }

    public static func isMatchingArchive(_ url: URL, bytes: Int, sha256: String) throws -> Bool {
        guard (1...maximumBytes).contains(bytes),
              try url.resourceValues(forKeys: [.fileSizeKey]).fileSize == bytes else { return false }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var total = 0
        while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
            total += chunk.count
            guard total <= bytes else { return false }
            hasher.update(data: chunk)
        }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return total == bytes && actual == sha256
    }
}

public enum UpdateInstallation {
    public static let stagePrefix = ".KongSlides-update-"

    public static func version(of app: URL) -> AppVersion? {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let values = try? app.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink == false,
              let data = try? Data(contentsOf: plist),
              let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              info["CFBundleIdentifier"] as? String == UpdateRepository.bundleID,
              info["CFBundleExecutable"] as? String == "KongSlides",
              let version = info["CFBundleShortVersionString"] as? String else { return nil }
        return AppVersion(version)
    }

    // lstat distinguishes a vacant location from an unrelated file, including a dangling symlink.
    public static func installedVersion(at app: URL) throws -> AppVersion? {
        var entry = stat()
        if lstat(app.path, &entry) != 0 {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard let version = version(of: app) else { throw CocoaError(.fileWriteFileExists) }
        return version
    }

    public static func install(_ candidate: URL, at destination: URL, replacing expected: AppVersion?) throws {
        guard try installedVersion(at: destination) == expected else {
            throw CocoaError(.fileWriteFileExists)
        }
        if expected == nil {
            try placeExclusively(candidate, at: destination)
        } else {
            try swap(destination, candidate)
        }
    }

    public static func placeExclusively(_ source: URL, at destination: URL) throws {
        let result = source.path.withCString { from in
            destination.path.withCString { to in
                renameatx_np(AT_FDCWD, from, AT_FDCWD, to, UInt32(RENAME_EXCL))
            }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    public static func swap(_ original: URL, _ replacement: URL) throws {
        let result = original.path.withCString { source in
            replacement.path.withCString { destination in
                renameatx_np(AT_FDCWD, source, AT_FDCWD, destination, UInt32(RENAME_SWAP))
            }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    @discardableResult
    public static func runSystemTool(_ path: String, arguments: [String]) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
