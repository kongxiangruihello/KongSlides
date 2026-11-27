import AppKit
import Foundation

struct HomeLibrary: Codable {
    struct Group: Codable, Identifiable, Equatable {
        var id = UUID()
        var name: String
    }

    struct Favorite: Codable, Identifiable, Equatable {
        let path: String
        var group: UUID?
        var id: String { path }
        var url: URL { URL(fileURLWithPath: path) }
    }

    struct Preview: Codable, Equatable {
        var title: String
        var section: String
        var page: Int
        var pageID: UUID?
        var total: Int
        var backups: Int
        var pendingRepairs: Int
        var thumbnailPNG: Data?
        var coverPNG: Data? = nil
        var preflightPages: Int?
    }

    var groups: [Group] = []
    var favorites: [Favorite] = []
    var recent: [String] = []
    var previews: [String: Preview] = [:]
    var lastEdited: String?

    static func path(_ url: URL) -> String { FavoriteDocuments.canonical(url).path }

    mutating func noteOpened(_ url: URL) {
        let path = Self.path(url)
        recent.removeAll { $0 == path }
        recent.insert(path, at: 0)
        recent = Array(recent.prefix(60))
        prunePreviews()
    }

    mutating func prunePreviews() {
        let keep = Set(recent + favorites.map(\.path) + (lastEdited.map { [$0] } ?? []))
        previews = previews.filter { keep.contains($0.key) }
        let images = Set(Array(recent.prefix(32)) + (lastEdited.map { [$0] } ?? []))
        for key in Array(previews.keys) where !images.contains(key) {
            previews[key]?.thumbnailPNG = nil
            previews[key]?.coverPNG = nil
        }
    }

    mutating func relocate(_ old: String, to url: URL) {
        let new = Self.path(url)
        guard new != old, let index = favorites.firstIndex(where: { $0.path == old }) else { return }
        let group = favorites[index].group
        favorites[index] = .init(path: new, group: group)
        favorites = favorites.enumerated().filter { $0.offset == index || $0.element.path != new }.map(\.element)
        var seen = Set<String>()
        recent = recent.map { $0 == old ? new : $0 }
        recent = recent.filter { seen.insert($0).inserted }
        if lastEdited == old { lastEdited = new }
        if let preview = previews.removeValue(forKey: old) { previews[new] = preview }
    }

    mutating func move(_ path: String, before target: String) {
        guard path != target,
              let origin = favorites.firstIndex(where: { $0.path == path }),
              let destination = favorites.firstIndex(where: { $0.path == target }) else { return }
        var favorite = favorites.remove(at: origin)
        favorite.group = favorites[origin < destination ? destination - 1 : destination].group
        favorites.insert(favorite, at: origin < destination ? destination - 1 : destination)
    }

    func portableBackup() -> HomeLibrary {
        var copy = self
        for path in Array(copy.previews.keys) {
            copy.previews[path]?.thumbnailPNG = nil
            copy.previews[path]?.coverPNG = nil
        }
        return copy
    }

    mutating func merge(_ backup: HomeLibrary) {
        var groupIDs: [UUID: UUID] = [:]
        for item in backup.groups {
            if let existing = groups.first(where: { $0.name == item.name }) {
                groupIDs[item.id] = existing.id
            } else {
                let group = Group(name: String(item.name.prefix(80)))
                groupIDs[item.id] = group.id
                groups.append(group)
            }
        }
        let known = Set(favorites.map(\.path))
        favorites += backup.favorites.filter { $0.path.hasPrefix("/") && !known.contains($0.path) }
            .map { Favorite(path: $0.path, group: $0.group.flatMap { groupIDs[$0] }) }
        var seen = Set<String>()
        favorites = favorites.filter { seen.insert($0.path).inserted }
        seen.removeAll()
        recent = Array((recent + backup.recent.filter { $0.hasPrefix("/") }).filter { seen.insert($0).inserted }.prefix(60))
        let acceptable = backup.previews.filter { $0.value.page > 0 && $0.value.page <= $0.value.total }
        previews.merge(acceptable, uniquingKeysWith: { current, _ in current })
        if lastEdited == nil, let path = backup.lastEdited, path.hasPrefix("/") { lastEdited = path }
        prunePreviews()
    }
}

struct FavoriteDocuments {
    private let defaults: UserDefaults
    private let key = "KongSlides.homeLibrary.v2"
    private let legacyKey = "KongSlides.favoriteDocuments.v1"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var persisted: HomeLibrary? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? PropertyListDecoder().decode(HomeLibrary.self, from: data)
    }

    var library: HomeLibrary {
        if let persisted { return persisted }
        var result = HomeLibrary()
        result.favorites = (defaults.stringArray(forKey: legacyKey) ?? []).map { .init(path: $0, group: nil) }
        return result
    }

    var urls: [URL] { library.favorites.map(\.url) }

    static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    func save(_ library: HomeLibrary) {
        if let bytes = try? PropertyListEncoder().encode(library) { defaults.set(bytes, forKey: key) }
    }

    func toggle(_ url: URL) {
        guard url.isFileURL else { return }
        var next = library
        let path = HomeLibrary.path(url)
        if next.favorites.contains(where: { $0.path == path }) { next.favorites.removeAll { $0.path == path } }
        else { next.favorites.insert(.init(path: path, group: nil), at: 0) }
        save(next)
    }
}

enum HomeThumbnail {
    static func render(_ slide: Slide, images: [UUID: Data], canvas: SlideCanvas) -> Data? {
        let scale = min(300 / canvas.width, 185 / canvas.height)
        let width = max(1, Int((canvas.width * scale).rounded()))
        let height = max(1, Int((canvas.height * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        SlideDrawing.draw(slide, images: images, in: context, canvas: canvas)
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
