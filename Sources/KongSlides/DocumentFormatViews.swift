import SwiftUI
import AppKit

struct CanvasSizeView: View {
    let deck: Deck
    let slideID: UUID
    let apply: (SlideCanvas) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var width = 960.0
    @State private var height = 540.0
    private var candidate: SlideCanvas { .init(width: width, height: height) }
    private var page: Slide { deck.slides.first { $0.id == slideID } ?? deck.slides[0] }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("幻灯片尺寸").font(.title2.weight(.semibold))
            Text("按比例缩放并居中留边，适用于整份课件。").foregroundStyle(.secondary)
            HStack {
                Button("16∶9") { set(.widescreen) }
                Button("4∶3") { set(.standard) }
                Spacer()
                TextField("宽（pt）", value: $width, format: .number).frame(width: 145)
                TextField("高（pt）", value: $height, format: .number).frame(width: 145)
            }
            if candidate.isValid {
                let fitted = page
                let source = deck.pageCanvas
                let transformed = fitted.objects.map { source.fitting($0, into: candidate) }
                SlideSurface(slide: Slide(background: fitted.background, objects: transformed),
                             images: deck.images, canvas: candidate).frame(maxHeight: 300)
            } else {
                Text("宽和高需在 24 至 2000 pt 之间。").foregroundStyle(.secondary)
            }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("应用到所有页") { apply(candidate); dismiss() }
                    .keyboardShortcut(.defaultAction).disabled(!candidate.isValid)
            }
        }
        .padding(22)
        .frame(width: 680)
        .onAppear { set(deck.pageCanvas) }
    }

    private func set(_ size: SlideCanvas) { width = size.width; height = size.height }
}

struct TextRunFormatView: View {
    let object: SlideObject
    let apply: ([SlideTextRun]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var runs: [SlideTextRun] = []
    @State private var selection: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("局部文字格式").font(.title2.weight(.semibold))
            HStack(alignment: .top) {
                List(Array(runs.indices), id: \.self, selection: $selection) { index in
                    let run = runs[index]
                    Text((object.text as NSString).substring(with: .init(location: run.start, length: run.length)))
                        .lineLimit(2).tag(index)
                }
                if let index = selection, runs.indices.contains(index) {
                    form(index).frame(width: 195)
                }
            }.frame(minHeight: 280)
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("应用") { apply(runs); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 650)
        .onAppear {
            runs = object.textRuns ?? [SlideTextRun(start: 0, length: object.text.utf16.count, size: object.fontSize,
                                                       bold: object.bold, color: object.color, fontName: object.textLayout?.fontName)]
            selection = runs.indices.first
        }
    }

    private func form(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("字号", value: Binding(get: { runs[index].size ?? object.fontSize },
                set: { runs[index].size = min(200, max(8, $0)) }), format: .number)
            Toggle("粗体", isOn: $runs[index].bold)
            TextField("字体名称", text: Binding(get: { runs[index].fontName ?? "" },
                set: { runs[index].fontName = $0.isEmpty ? nil : $0 }))
            ColorPicker("颜色", selection: Binding(
                get: { Color(nsColor: Palette.color(runs[index].color)) },
                set: { color in
                    guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                    runs[index].color = String(format: "%02X%02X%02X",
                        Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()),
                        Int((rgb.blueComponent * 255).rounded()))
                }), supportsOpacity: false)
            Picker("基线", selection: $runs[index].baseline) {
                Text("正常").tag(0.0)
                Text("上标").tag(0.3)
                Text("下标").tag(-0.25)
                let value = runs[index].baseline
                if ![0, 0.3, -0.25].contains(value) { Text("原稿").tag(value) }
            }
        }
    }
}
