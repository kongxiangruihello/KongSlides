import AppKit
import SwiftUI

struct EditorPanelCloseButton: View {
    let title: String
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }
}

struct EditorFormattingToolbar: View {
    let object: SlideObject?
    let ranges: [Range<Int>]
    let insertTextBox: () -> Void
    let update: ((inout SlideObject) -> Void) -> Void
    @State private var fontFamilies: [String] = []
    @State private var customSize = false
    @State private var sizeInput = ""

    private let sizes: [Double] = [8, 9, 10, 11, 12, 13.5, 14, 16, 18, 20, 24, 28, 32, 36, 44, 54, 60, 72, 96]
    private var textRanges: [Range<Int>] { ranges.filter { !$0.isEmpty } }
    private var styles: [SlideTextRun] { object?.formattingStyles(in: textRanges) ?? [] }
    private var primary: SlideTextRun? { styles.first }
    private var size: Double { primary?.size ?? object?.fontSize ?? 36 }
    private var font: String? { primary?.usesSystemFont == true ? nil : primary?.fontName ?? object?.textLayout?.fontName }
    private var paragraphs: [SlideParagraph] {
        guard let object else { return [] }
        let values = object.paragraphStyles
        return object.paragraphIndices(in: ranges).map { values[$0] }
    }

    var body: some View {
        HStack(spacing: 9) {
            Button(action: insertTextBox) { Label("文本框", systemImage: "textbox") }
                .buttonStyle(.bordered)
                .help("添加文本框（⌘⇧T）")
                .accessibilityIdentifier("insert-text-box")
                .keyboardShortcut("t", modifiers: [.command, .shift])
            rule
            HStack(spacing: 4) {
                tool("项目符号", icon: "list.bullet", active: selectedBullets(numbered: false)) { bullets(numbered: false) }
                tool("编号", icon: "list.number", active: selectedBullets(numbered: true)) { bullets(numbered: true) }
            }
            .disabled(object == nil)
            .help(object == nil ? "先选中文本框，再设置项目符号或编号" : "")
            rule
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    fontMenu
                    sizeMenu
                    tool("增大字号", icon: "textformat.size.larger") { changeSize(by: true) }
                    tool("减小字号", icon: "textformat.size.smaller") { changeSize(by: false) }
                    tool("清除文字格式", icon: "eraser") { clearFormatting() }
                    rule
                    tool("粗体", icon: "bold", active: isActive { $0.bold }) {
                        let value = !isActive { $0.bold }
                        format { $0.bold = value }
                    }
                    tool("斜体", icon: "italic", active: characterActive(\.italic)) { toggle(\.italic) }
                    tool("下划线", icon: "underline", active: characterActive(\.underline)) { toggle(\.underline) }
                    tool("删除线", icon: "strikethrough", active: characterActive(\.strikethrough)) { toggle(\.strikethrough) }
                    tool("上标", icon: "textformat.superscript", active: isActive { $0.baseline > 0 }) {
                        let value = isActive { $0.baseline > 0 } ? 0 : 0.3
                        format { $0.baseline = value }
                    }
                    tool("下标", icon: "textformat.subscript", active: isActive { $0.baseline < 0 }) {
                        let value = isActive { $0.baseline < 0 } ? 0 : -0.25
                        format { $0.baseline = value }
                    }
                    compactMenu("字间距", icon: "arrow.left.and.right") {
                        spacing("紧密", -1.5)
                        spacing("标准", 0)
                        spacing("加宽", 1.5)
                        spacing("更宽", 3)
                    }
                    compactMenu("更改大小写", icon: "textformat") {
                        Button("全部大写") { update { $0.changeLetterCase(in: textRanges, uppercase: true) } }
                        Button("全部小写") { update { $0.changeLetterCase(in: textRanges, uppercase: false) } }
                    }
                    compactMenu("文字高亮", icon: "highlighter", color: primary?.characterStyle?.highlight ?? "FFE766") {
                        Button("取消高亮") { changeCharacter { $0.highlight = nil } }
                        colorChoices([("黄色", "FFE766"), ("绿色", "B7EB90"), ("浅蓝", "A9DBFA"),
                                      ("粉色", "F8B9D9"), ("橙色", "FFD092")]) { value in
                            changeCharacter { $0.highlight = value }
                        }
                    }
                    compactMenu("文字颜色", icon: "character", color: primary?.color ?? Palette.ink) {
                        colorChoices([("墨黑", Palette.ink), ("红色", "D62637"), ("蓝色", "2257BC"),
                                      ("绿色", "287840"), ("紫色", Palette.indigo), ("白色", "FFFFFF")]) { value in
                            format { $0.color = value }
                        }
                    }
                    rule
                    tool("减少缩进", icon: "decrease.indent") { indent(by: -16) }
                    tool("增加缩进", icon: "increase.indent") { indent(by: 16) }
                    rule
                    alignment("左对齐", "text.alignleft", .left)
                    alignment("居中", "text.aligncenter", .center)
                    alignment("右对齐", "text.alignright", .right)
                    alignment("两端对齐", "text.justify", .justified)
                    alignment("分散对齐", "text.justify.left", .distributed)
                    compactMenu("行距", icon: "line.3.horizontal.decrease") {
                        lineSpacing("单倍行距", 1)
                        lineSpacing("1.25 倍行距", 1.25)
                        lineSpacing("1.5 倍行距", 1.5)
                        lineSpacing("双倍行距", 2)
                    }
                }
                .disabled(object == nil)
            }
            .scrollIndicators(.hidden)
        }
        .frame(height: 36)
        .padding(.horizontal, 14)
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear {
            if fontFamilies.isEmpty {
                fontFamilies = NSFontManager.shared.availableFontFamilies.sorted {
                    $0.localizedStandardCompare($1) == .orderedAscending
                }
            }
        }
        .alert("输入字号", isPresented: $customSize) {
            TextField("8–200", text: $sizeInput)
            Button("取消", role: .cancel) {}
            Button("应用") {
                if let value = Double(sizeInput.trimmingCharacters(in: .whitespaces)), (8...200).contains(value) {
                    format { $0.size = value }
                }
            }
        } message: { Text("可输入 8 到 200 磅，支持小数。") }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("常用工具")
    }

    private var rule: some View { Divider().frame(height: 20).padding(.horizontal, 3) }

    private var fontMenu: some View {
        Menu {
            Button("系统字体") { setFont(nil) }
            let preferred = ["Songti SC", "PingFang SC", "Heiti SC", "Kaiti SC", "Arial", "Times New Roman"]
                .filter { fontFamilies.contains($0) }
            ForEach(preferred, id: \.self) { value in Button(value) { setFont(value) } }
            Divider()
            Menu("所有本机字体") {
                ForEach(fontFamilies, id: \.self) { value in Button(value) { setFont(value) } }
            }
        } label: {
            Text(font ?? "系统字体").lineLimit(1).frame(width: 112, alignment: .leading)
        }
        .fixedSize()
        .accessibilityLabel("字体")
        .help("字体")
    }

    private var sizeMenu: some View {
        Menu {
            ForEach(sizes, id: \.self) { value in
                Button(value.formatted()) { format { $0.size = value } }
            }
            Button("自定义字号…") { sizeInput = String(size); customSize = true }
        } label: {
            Text(object == nil ? "—" : size.formatted(.number.precision(.fractionLength(0...2))))
                .monospacedDigit().frame(minWidth: 30)
        }
        .fixedSize()
        .accessibilityLabel("字号")
        .help("字号")
    }

    private func tool(_ title: String, icon: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .frame(width: 26, height: 25)
                .foregroundStyle(active ? Color.accentColor : Color.primary)
                .background(active ? Color.accentColor.opacity(0.16) : .clear, in: .rect(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func compactMenu<Content: View>(_ title: String, icon: String, color: String? = nil,
                                             @ViewBuilder content: () -> Content) -> some View {
        let entries = content()
        return Menu { entries } label: {
            VStack(spacing: 1) {
                Image(systemName: icon)
                if let color { Rectangle().fill(Color(nsColor: Palette.color(color))).frame(width: 14, height: 2) }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(title)
        .accessibilityLabel(title)
    }

    private func colorChoices(_ choices: [(String, String)], apply: @escaping (String) -> Void) -> some View {
        ForEach(choices.indices, id: \.self) { index in
            let (name, value) = choices[index]
            Button(name) { apply(value) }
        }
    }

    private func isActive(_ predicate: (SlideTextRun) -> Bool) -> Bool {
        !styles.isEmpty && styles.allSatisfy(predicate)
    }

    private func characterActive(_ key: KeyPath<SlideCharacterStyle, Bool>) -> Bool {
        isActive { $0.characterStyle?[keyPath: key] == true }
    }

    private func toggle(_ key: WritableKeyPath<SlideCharacterStyle, Bool>) {
        let value = !characterActive(key)
        changeCharacter { $0[keyPath: key] = value }
    }

    private func format(_ transform: @escaping (inout SlideTextRun) -> Void) {
        update { $0.formatCharacters(in: textRanges, transform) }
    }

    private func changeCharacter(_ transform: @escaping (inout SlideCharacterStyle) -> Void) {
        format { run in
            var value = run.characterStyle ?? .init()
            transform(&value)
            run.characterStyle = value == .init() ? nil : value
        }
    }

    private func setFont(_ family: String?) {
        let useSystem = family == nil && !textRanges.isEmpty && object?.textLayout?.fontName != nil
        format {
            $0.fontName = family
            $0.usesSystemFont = useSystem ? true : nil
        }
    }

    private func clearFormatting() {
        format {
            $0.size = 36
            $0.bold = false
            $0.color = Palette.ink
            $0.fontName = nil
            $0.usesSystemFont = !textRanges.isEmpty && object?.textLayout?.fontName != nil ? true : nil
            $0.baseline = 0
            $0.characterStyle = nil
        }
    }

    private func changeSize(by increase: Bool) {
        let step = size < 20 ? 1.0 : 2.0
        format { $0.size = min(200, max(8, size + (increase ? step : -step))) }
    }

    private func spacing(_ title: String, _ value: Double) -> some View {
        Button(title) { changeCharacter { $0.spacing = value } }
    }

    private func selectedBullets(numbered: Bool) -> Bool {
        !paragraphs.isEmpty && paragraphs.allSatisfy { $0.hasList(numbered: numbered) }
    }

    private func bullets(numbered: Bool) {
        update { $0.toggleList(in: ranges, numbered: numbered) }
    }

    private func indent(by value: Double) {
        update { $0.formatParagraphs(in: ranges) { _, paragraph in
            paragraph.left = min(max(0, (object?.width ?? 720) - 50), max(0, paragraph.left + value))
        } }
    }

    private func alignment(_ label: String, _ icon: String, _ value: SlideParagraph.Alignment) -> some View {
        tool(label, icon: icon, active: !paragraphs.isEmpty && paragraphs.allSatisfy { $0.alignment == value }) {
            update { $0.formatParagraphs(in: ranges) { _, paragraph in paragraph.alignment = value } }
        }
    }

    private func lineSpacing(_ title: String, _ multiple: Double) -> some View {
        Button(title) {
            update { $0.formatParagraphs(in: ranges) { _, paragraph in
                paragraph.lineMultiple = multiple
                paragraph.lineHeight = nil
            } }
        }
    }
}
