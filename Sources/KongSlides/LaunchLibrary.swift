import Foundation

struct FavoriteDocuments {
    private let defaults: UserDefaults
    private let key = "KongSlides.favoriteDocuments.v1"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var urls: [URL] {
        (defaults.stringArray(forKey: key) ?? []).map { URL(fileURLWithPath: $0) }
    }

    static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    func toggle(_ url: URL) {
        guard url.isFileURL else { return }
        let path = Self.canonical(url).path
        var paths = urls.map { Self.canonical($0).path }
        if paths.contains(path) { paths.removeAll { $0 == path } }
        else { paths.insert(path, at: 0) }
        defaults.set(paths, forKey: key)
    }
}
