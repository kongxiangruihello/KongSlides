import CoreGraphics
import Foundation
import ImageIO

/// Small previews and full editor images have independent memory budgets.
final class SlideImageCache: @unchecked Sendable {
    private final class Entry {
        let data: Data
        let image: CGImage

        init(data: Data, image: CGImage) {
            self.data = data
            self.image = image
        }
    }

    private let previews = NSCache<NSUUID, Entry>()
    private let full = NSCache<NSUUID, Entry>()
    private let previewLock = NSLock()
    private let fullLock = NSLock()

    init() {
        previews.totalCostLimit = 24 * 1024 * 1024
        full.totalCostLimit = 96 * 1024 * 1024
    }

    func picture(_ data: Data, id: UUID, thumbnail: Bool) -> CGImage? {
        let cache = thumbnail ? previews : full
        let key = id as NSUUID
        let lock = thumbnail ? previewLock : fullLock
        // A single decode per variant, including concurrently rendered thumbnail rows.
        lock.lock()
        defer { lock.unlock() }
        if let existing = cache.object(forKey: key), existing.data == data { return existing.image }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        let image: CGImage?
        if thumbnail {
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: 384
            ] as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(source, 0, options)
        } else {
            image = CGImageSourceCreateImageAtIndex(source, 0, options)
        }
        guard let image else { return nil }
        let (rasterCost, overflow) = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
        let (cost, storageOverflow) = rasterCost.addingReportingOverflow(data.count)
        if !overflow, !storageOverflow, cost <= cache.totalCostLimit {
            cache.setObject(Entry(data: data, image: image), forKey: key, cost: cost)
        }
        return image
    }
}
