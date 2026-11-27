import AppKit
import PDFKit
import SwiftUI

struct ExportReceipt: Identifiable {
    var id = UUID()
    let url: URL
    var success = true
    var report: [String] = []
}

enum ClassroomExport {
    static func checkPowerPoint(_ expected: Deck, at url: URL) -> [String] {
        do {
            let actual = try PowerPoint.read(url, prepareImage: { $0 }).deck
            var messages: [String] = []
            if actual.slides.count != expected.slides.count {
                messages.append("页数有差异：原有 \(expected.slides.count)，读回 \(actual.slides.count)。")
            }
            func kinds(_ slide: Slide) -> [SlideObject.Kind: Int] {
                Dictionary(grouping: slide.objects.filter { $0.decorationSource == nil }, by: \.kind).mapValues(\.count)
            }
            for (index, pages) in zip(expected.slides, actual.slides).enumerated() {
                var flags: [String] = []
                if pages.0.speakerNotes != pages.1.speakerNotes { flags.append("讲稿") }
                if pages.0.isBackup != pages.1.isBackup { flags.append("备用页标记") }
                if kinds(pages.0) != kinds(pages.1) { flags.append("可编辑对象数量") }
                if pages.1.importReport?.diagnostics.contains(where: { $0.impact == .pageUnavailable }) == true {
                    flags.append("整页未能读回")
                }
                if !flags.isEmpty { messages.append("第 \(index + 1) 页：\(flags.joined(separator: "、"))") }
            }
            return messages.isEmpty
                ? ["已回读 \(actual.slides.count) 页。页数、讲稿、备用页和可编辑对象数量通过核对。"]
                : messages
        } catch {
            return ["PPTX 已写入，但回读未完成：\(error.localizedDescription)"]
        }
    }

    static func compatibilityCopy(_ deck: Deck, sources: [String], replacement: String?, flatten: Set<UUID>) throws -> Deck {
        var output = deck
        if let replacement {
            for name in sources { SlideFonts.replace(name, with: replacement, in: &output) }
        }
        for index in output.slides.indices where flatten.contains(output.slides[index].id) {
            let slide = output.slides[index]
            guard let data = image(slide, images: output.images, canvas: output.pageCanvas) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let id = UUID()
            output.images[id] = data
            let canvas = deck.pageCanvas
            output.slides[index].objects = [SlideObject(kind: .image, x: 0, y: 0, width: canvas.width,
                                                       height: canvas.height, imageID: id)]
        }
        output.courseFooter = nil
        return try output.validated()
    }

    static func image(_ slide: Slide, images: [UUID: Data], canvas: SlideCanvas, longEdge: Double = 1920) -> Data? {
        let scale = longEdge / max(canvas.width, canvas.height)
        guard let context = CGContext(data: nil, width: max(1, Int(canvas.width * scale)),
                                      height: max(1, Int(canvas.height * scale)), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        SlideDrawing.draw(slide, images: images, in: context, canvas: canvas)
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}

struct ExportReceiptView: View {
    let receipt: ExportReceipt
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(receipt.success ? "文件已保存" : "写入未完成",
                  systemImage: receipt.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.title2.bold())
            Text(receipt.url.lastPathComponent).font(.headline)
            Text(receipt.url.deletingLastPathComponent().path).font(.caption).textSelection(.enabled)
            if !receipt.report.isEmpty {
                ScrollView {
                    Text(receipt.report.joined(separator: "\n")).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 220)
            }
            HStack {
                Spacer()
                Button(receipt.success ? "在 Finder 中显示" : "打开目标文件夹") {
                    if receipt.success { NSWorkspace.shared.activateFileViewerSelecting([receipt.url]) }
                    else { NSWorkspace.shared.open(receipt.url.deletingLastPathComponent()) }
                }
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 500)
    }
}

struct ClassroomCompatibilityView: View {
    let deck: Deck
    let apply: ([String], String?, Set<UUID>) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var sources = Set<String>()
    @State private var flattened = Set<UUID>()
    @State private var replacement = ""
    private var fonts: [String] { SlideFonts.requested(in: deck) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("教室兼容 PPTX 副本").font(.title2.bold())
            Text("勾选教室电脑可能缺少的字体，或选出需要保留原样的页面。选中的页面会转成图片。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                List(fonts, id: \.self, selection: $sources) { font in
                    Text(SlideFonts.named(font, size: 12) == nil ? "\(font) · 本机缺少" : font).tag(font)
                }
                List(Array(deck.slides.enumerated()), id: \.element.id, selection: $flattened) { index, slide in
                    Text("\(index + 1)  \(slide.title)").tag(slide.id)
                }
            }
            HStack {
                TextField("副本使用的替代字体", text: $replacement).disabled(sources.isEmpty)
                if !sources.isEmpty && !replacement.isEmpty && !hasFont { Text("本机未找到该字体").foregroundStyle(.orange) }
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("选择保存位置…") {
                    apply(sources.sorted(), sources.isEmpty ? nil : replacement, flattened)
                    dismiss()
                }.disabled((sources.isEmpty && flattened.isEmpty) || (!sources.isEmpty && !hasFont))
            }
        }.padding(20).frame(width: 695, height: 370)
    }

    private var hasFont: Bool { !replacement.isEmpty && SlideFonts.named(replacement, size: 12) != nil }
}

enum ClassroomPerformance {
    static func measure(_ deck: Deck) throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let native = directory.appendingPathComponent("benchmark.kongslides")
        let pptx = directory.appendingPathComponent("benchmark.pptx")
        var time = OpenTiming.now
        try SlidesDocument(deck: deck).writeNative(to: native)
        let save = OpenTiming.now - time
        time = OpenTiming.now
        let read = try SlidesDocument.readNative(native).deck
        if let first = read.slides.first {
            _ = ClassroomExport.image(first, images: read.images, canvas: read.pageCanvas, longEdge: 960)
        }
        let firstFrame = OpenTiming.now - time
        time = OpenTiming.now
        let sample = Array(read.slides.prefix(30))
        for page in sample { _ = ClassroomExport.image(page, images: read.images, canvas: read.pageCanvas, longEdge: 960) }
        let turns = OpenTiming.now - time
        time = OpenTiming.now
        try PowerPoint.write(read, to: pptx)
        let export = OpenTiming.now - time
        func ms(_ seconds: Double) -> Int { Int((seconds * 1000).rounded()) }
        return "\(read.slides.count) 页，\(read.images.count) 张素材\n原生读取与首帧渲染：\(ms(firstFrame)) ms\n连续渲染 \(sample.count) 页：\(ms(turns)) ms\n原生保存：\(ms(save)) ms\n另存 PPTX：\(ms(export)) ms"
    }
}

struct PerformanceBenchmarkView: View {
    let deck: Deck
    @Environment(\.dismiss) private var dismiss
    @State private var result = ""
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("长课件性能测量").font(.title2.bold())
            Text("用当前课件测量磁盘读写、首帧和连续页面渲染。").font(.caption)
            Text(result).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                if running { ProgressView().controlSize(.small) }
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("测量当前课件") { measure() }.disabled(running)
            }
        }.padding(20).frame(width: 450)
    }

    private func measure() {
        running = true
        Task {
            defer { running = false }
            do { result = try await Task.detached(priority: .utility) { try ClassroomPerformance.measure(deck) }.value }
            catch { result = error.localizedDescription }
        }
    }
}

struct StudentHandoutPreview: View {
    let deck: Deck
    let format: TeachingPDF.Format
    let save: (Data) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var hideTeacher = true
    @State private var includeBackups = false
    @State private var preview: Data?
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("学生配布稿预览").font(.title2.bold())
                Spacer()
                Toggle("隐藏答案页与教师批注", isOn: $hideTeacher)
                Toggle("包含备用页", isOn: $includeBackups)
            }
            if let preview, let pdf = PDFDocument(data: preview) {
                HandoutPDFView(document: pdf).id(preview)
            } else if let failure { Text(failure).frame(maxHeight: .infinity) }
            else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            HStack {
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("导出预览中的 PDF…") {
                    if let preview { save(preview); dismiss() }
                }.disabled(preview == nil)
            }
        }
        .padding(16).frame(width: 750, height: 590)
        .task(id: (hideTeacher ? 2 : 0) + (includeBackups ? 1 : 0)) { await render() }
    }

    private func render() async {
        preview = nil
        failure = nil
        let hidden = hideTeacher
        let backups = includeBackups
        let input = deck
        let outputFormat = format
        do {
            let data = try await Task.detached(priority: .userInitiated) {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
                defer { try? FileManager.default.removeItem(at: url) }
                let copy = input.studentCopy(hideTeacherContent: hidden, includeBackups: backups)
                let sourceNumbers = Dictionary(uniqueKeysWithValues: input.slides.enumerated().map { ($0.element.id, $0.offset + 1) })
                try TeachingPDF.write(copy, format: outputFormat, includeBackups: backups, sourcePageNumbers: sourceNumbers, includeTeacherContent: !hidden, to: url)
                return try Data(contentsOf: url)
            }.value
            if !Task.isCancelled { preview = data }
        } catch { if !Task.isCancelled { failure = error.localizedDescription } }
    }
}

private struct HandoutPDFView: NSViewRepresentable {
    let document: PDFDocument
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) { view.document = document }
}
