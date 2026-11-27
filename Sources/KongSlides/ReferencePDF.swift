import AppKit
import PDFKit
import SwiftUI

enum ReferencePDFError: LocalizedError {
    case unavailable, locked, invalidPage

    var errorDescription: String? {
        switch self {
        case .unavailable: "无法读取参考 PDF，请确认文件已完整下载。"
        case .locked: "参考 PDF 已锁定，请先解锁并保存一份副本。"
        case .invalidPage: "无法渲染这一页。请核对参考 PDF 的页码和页面大小。"
        }
    }
}

enum ReferencePDF {
    static func pageIndex(for slide: Slide, position: Int, pageCount: Int) -> Int? {
        let index = (slide.importReport?.sourcePage ?? (position + 1)) - 1
        return (0..<pageCount).contains(index) ? index : nil
    }

    static func image(in document: CGPDFDocument, page index: Int) throws -> CGImage {
        if document.isEncrypted && !document.isUnlocked { throw ReferencePDFError.locked }
        guard index >= 0, index < document.numberOfPages, let page = document.page(at: index + 1) else {
            throw ReferencePDFError.invalidPage
        }
        let crop = page.getBoxRect(.cropBox)
        let rotated = page.rotationAngle % 180 != 0
        let rawWidth = rotated ? crop.height : crop.width
        let rawHeight = rotated ? crop.width : crop.height
        guard rawWidth.isFinite, rawHeight.isFinite, rawWidth > 0, rawHeight > 0 else {
            throw ReferencePDFError.invalidPage
        }
        let largest = max(rawWidth, rawHeight)
        let width = max(1, Int((rawWidth / largest * 2400).rounded()))
        let height = max(1, Int((rawHeight / largest * 2400).rounded()))
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ReferencePDFError.invalidPage
        }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(bounds)
        context.concatenate(page.getDrawingTransform(.cropBox, rect: bounds, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { throw ReferencePDFError.invalidPage }
        return image
    }

    static func replace(_ slide: inout Slide, with asset: UUID, size: CGSize, canvas: SlideCanvas = .widescreen, repair: SlideImportReport.Repair? = nil) {
        let frame = canvas.size
        let scale: CGFloat = min(frame.width / size.width, frame.height / size.height)
        let width: Double = Double(size.width * scale)
        let height: Double = Double(size.height * scale)
        if slide.originalPDFPage == nil {
            slide.originalPDFPage = .init(background: slide.background, objects: slide.objects, previousRepair: slide.importReport?.repair)
        }
        slide.background = "FFFFFF"
        slide.objects = [SlideObject(kind: .image, x: (Double(frame.width) - width) / 2,
                                     y: (Double(frame.height) - height) / 2, width: width, height: height, imageID: asset)]
        if let repair { slide.importReport?.repair = repair }
    }
}

struct ReferencePDFView: View {
    let url: URL
    let deck: Deck
    let selectedSlide: UUID
    let replace: (UUID, Int, URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var document: PDFDocument?
    @State private var slideIndex = 0
    @State private var pdfIndex: Int?
    @State private var error: String?
    @State private var confirming = false
    @State private var overlay = false
    @State private var opacity = 0.5
    @State private var overlayImage: CGImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("对照原稿 PDF").font(.title2.weight(.semibold))
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let error {
                Text(error).foregroundStyle(.secondary)
            } else if let document, deck.slides.indices.contains(slideIndex) {
                navigation(document)
                if overlay, let overlayImage {
                    ZStack {
                        SlideSurface(slide: deck.slides[slideIndex], images: deck.images, canvas: deck.pageCanvas)
                        Image(decorative: overlayImage, scale: 1)
                            .resizable().scaledToFit().opacity(opacity)
                    }
                    .aspectRatio(deck.pageCanvas.width / deck.pageCanvas.height, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    HStack(spacing: 14) {
                        VStack(alignment: .leading) {
                            Text("当前课件　\(deck.slides[slideIndex].title)").font(.headline).lineLimit(1)
                            SlideSurface(slide: deck.slides[slideIndex], images: deck.images, canvas: deck.pageCanvas)
                                .border(.secondary.opacity(0.25))
                                .frame(maxHeight: .infinity, alignment: .center)
                        }
                        VStack(alignment: .leading) {
                            Text(url.lastPathComponent).font(.headline).lineLimit(1)
                            if let pdfIndex {
                                ReferencePageView(document: document, index: pdfIndex).id(pdfIndex)
                                    .border(.secondary.opacity(0.25))
                            } else {
                                ContentUnavailableView("没有匹配的参考页", systemImage: "doc.text.magnifyingglass",
                                                       description: Text("可在上方手动选择 PDF 页码。"))
                            }
                        }
                    }
                }
                HStack {
                    Toggle("叠加对照", isOn: $overlay).disabled(pdfIndex == nil)
                    if overlay {
                        Slider(value: $opacity, in: 0...1) { Text("参考页不透明度") }.frame(maxWidth: 190)
                    }
                    Spacer()
                }
                HStack {
                    Text("按源页码配对。PDF 的页序不同时，可手动选择参考页。")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("以参考页替换当前页…") { confirming = true }.disabled(pdfIndex == nil)
                }
            } else {
                ProgressView("正在打开参考 PDF…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(20)
        .frame(minWidth: 880, minHeight: 560)
        .task {
            slideIndex = deck.slides.firstIndex(where: { $0.id == selectedSlide }) ?? 0
            guard let opened = PDFDocument(url: url), opened.pageCount > 0 || opened.isLocked else {
                error = ReferencePDFError.unavailable.localizedDescription
                return
            }
            guard !opened.isLocked else { error = ReferencePDFError.locked.localizedDescription; return }
            document = opened
            pairPage()
        }
        .task(id: overlay ? pdfIndex : nil) {
            overlayImage = nil
            guard overlay, let pdfIndex else { return }
            let url = self.url
            let image = await Task.detached(priority: .userInitiated) {
                guard let source = CGPDFDocument(url as CFURL) else { return nil as CGImage? }
                return try? ReferencePDF.image(in: source, page: pdfIndex)
            }.value
            if !Task.isCancelled { overlayImage = image }
        }
        .alert("用参考 PDF 页面替换当前页？", isPresented: $confirming) {
            Button("替换") {
                if let pdfIndex, deck.slides.indices.contains(slideIndex) {
                    replace(deck.slides[slideIndex].id, pdfIndex, url)
                    dismiss()
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            let slide = deck.slides[slideIndex]
            Text("课件第 \(slideIndex + 1) 页将替换为 PDF 第 \((pdfIndex ?? 0) + 1) 页的图片。"
                 + (slide.isBackup ? "本页仍为备用页。" : "本页仍参与放映。")
                 + (slide.speakerNotes.isEmpty ? "" : "本页讲稿会保留。")
                 + "可用 ⌘Z 撤销。")
        }
    }

    private func navigation(_ doc: PDFDocument) -> some View {
        HStack {
            Button { selectSlide(-1) } label: { Image(systemName: "chevron.left") }.disabled(slideIndex == 0)
            Text("课件第 \(slideIndex + 1) / \(deck.slides.count) 页").monospacedDigit()
            Button { selectSlide(1) } label: { Image(systemName: "chevron.right") }
                .disabled(slideIndex + 1 >= deck.slides.count)
            if let sourcePage = deck.slides[slideIndex].importReport?.sourcePage {
                Text("源第 \(sourcePage) 页").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("参考 PDF 页码", selection: $pdfIndex) {
                Text("未配对").tag(nil as Int?)
                ForEach(0..<doc.pageCount, id: \.self) { index in Text(String(index + 1)).tag(Optional(index)) }
            }.fixedSize()
            Button("按源页码配对", action: pairPage)
        }
    }

    private func selectSlide(_ delta: Int) {
        let newIndex = slideIndex + delta
        if deck.slides.indices.contains(newIndex) { slideIndex = newIndex; pairPage() }
    }

    private func pairPage() {
        pdfIndex = ReferencePDF.pageIndex(for: deck.slides[slideIndex], position: slideIndex,
                                          pageCount: document?.pageCount ?? 0)
    }
}

private struct ReferencePageView: NSViewRepresentable {
    let document: PDFDocument
    let index: Int

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePage
        view.displayBox = .cropBox
        view.autoScales = true
        view.document = document
        if let page = document.page(at: index) { view.go(to: page) }
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
        if let page = document.page(at: index), view.currentPage !== page { view.go(to: page) }
    }
}
