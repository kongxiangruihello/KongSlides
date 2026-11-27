import Foundation
import Combine

struct TeachingTemplate: Codable, Identifiable {
    var id = UUID()
    var name: String
    var slide: Slide
    var images: [UUID: Data] = [:]
    var canvas: SlideCanvas?

    init(name: String, slide: Slide, images: [UUID: Data] = [:], canvas: SlideCanvas? = nil) {
        self.name = name
        self.canvas = canvas
        self.slide = slide
        self.slide.section = ""
        self.slide.speakerNotes = ""
        self.slide.importReport = nil
        self.slide.hiddenInShow = nil
        self.images = SlideClipboard(slides: [slide], images: images).images
    }

    var slots: [Int] {
        slide.objects.indices.filter { slide.objects[$0].kind == .text }.sorted {
            let first = slide.objects[$0]
            let second = slide.objects[$1]
            if first.y != second.y { return first.y < second.y }
            if first.x != second.x { return first.x < second.x }
            return $0 < $1
        }
    }

    var canGenerate: Bool { slots.count >= 2 }

    static let classroom = TeachingTemplate(name: "课堂通用", slide: Slide(objects: [
        SlideObject(x: 64, y: 55, width: 832, height: 95, text: "标题", fontSize: 43, bold: true),
        SlideObject(x: 64, y: 165, width: 822, height: 320, text: "正文", fontSize: 32),
        SlideObject(kind: .rectangle, x: 64, y: 37, width: 74, height: 6, color: Palette.indigo)
    ]))

    static let classic = TeachingTemplate(name: "经典导读", slide: Slide(background: "F1F4FB", objects: [
        SlideObject(kind: .rectangle, x: 47, y: 136, width: 866, height: 350, color: "FFFFFF"),
        SlideObject(x: 60, y: 41, width: 840, height: 85, text: "原文标题", fontSize: 41, bold: true, color: Palette.indigo),
        SlideObject(x: 77, y: 161, width: 806, height: 300, text: "原文与要点", fontSize: 32)
    ]))

    static let builtIns = [classroom, classic]
}

@MainActor
final class TeachingTemplateStore: ObservableObject {
    static let shared = TeachingTemplateStore()

    @Published private(set) var items: [TeachingTemplate] = []
    private let file: URL
    private var loadError: Error?

    init(file: URL? = nil) {
        self.file = file ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KongSlides", isDirectory: true).appendingPathComponent("TeachingTemplates.json")
        do {
            let data = try Data(contentsOf: self.file)
            let decoded = try JSONDecoder().decode([TeachingTemplate].self, from: data)
            guard Set(decoded.map(\.id)).count == decoded.count else { throw CocoaError(.fileReadCorruptFile) }
            for item in decoded { _ = try Deck(slides: [item.slide], images: item.images).validated() }
            items = decoded
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            items = []
        } catch {
            loadError = error
        }
    }

    func save(_ item: TeachingTemplate) throws {
        _ = try Deck(slides: [item.slide], images: item.images).validated()
        try persist(items + [item])
    }

    func remove(_ ids: Set<UUID>) throws {
        try persist(items.filter { !ids.contains($0.id) })
    }

    private func persist(_ updated: [TeachingTemplate]) throws {
        if let loadError { throw loadError }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(updated).write(to: file, options: .atomic)
        items = updated
    }
}
