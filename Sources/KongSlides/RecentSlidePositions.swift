import Foundation

/// Local navigation history. Page UUIDs survive insertion and reordering in a saved deck.
struct RecentSlidePositions {
    private struct Entry: Codable {
        let path: String
        let page: UUID
    }

    let defaults: UserDefaults
    private let key = "KongSlides.recentSlidePositions.v1"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func page(for url: URL) -> UUID? {
        let path = fileKey(url)
        return entries.first { $0.path == path }?.page
    }

    func remember(_ page: UUID, for url: URL) {
        let path = fileKey(url)
        var updated = entries
        if updated.first?.path == path && updated.first?.page == page { return }
        updated.removeAll { $0.path == path }
        updated.insert(Entry(path: path, page: page), at: 0)
        if let data = try? PropertyListEncoder().encode(Array(updated.prefix(200))) {
            defaults.set(data, forKey: key)
        }
    }

    private var entries: [Entry] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? PropertyListDecoder().decode([Entry].self, from: data)) ?? []
    }

    private func fileKey(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
