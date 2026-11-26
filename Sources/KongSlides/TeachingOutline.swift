import Foundation

enum TeachingDestination: String, CaseIterable, Identifiable {
    case projection, notes

    var id: Self { self }
    var label: String { self == .projection ? "投影" : "讲稿" }
}

struct TeachingBlock: Identifiable {
    var id = UUID()
    var text: String
    var destination: TeachingDestination
}

struct TeachingDraft: Identifiable {
    var id = UUID()
    var section: String
    var title: String
    var blocks: [TeachingBlock] = []

    var notes: String { blocks.filter { $0.destination == .notes }.map(\.text).joined(separator: "\n\n") }
    var projection: String { blocks.filter { $0.destination == .projection }.map(\.text).joined(separator: "\n\n") }
}

enum TeachingOutlineError: LocalizedError {
    case noContent, tooLarge, boxTooSmall(String)

    var errorDescription: String? {
        switch self {
        case .noContent: "请输入提纲或讲稿。"
        case .tooLarge: "内容过长，或生成的幻灯片超过 500 页。请按章节分批生成。"
        case .boxTooSmall(let title): "「\(title)」无法放入当前版式的文字区域。请改用较大的版式或缩短标题。"
        }
    }
}

enum TeachingOutline {
    static let example = """
    # 《论语》中的礼乐

    ## 从礼仪到礼义

    ### 人而不仁，如礼何
    > 子曰：“人而不仁，如礼何？人而不仁，如乐何？”

    - 礼乐能维持秩序
    - 仁规定了实践礼乐的态度

    【讲稿】
    请先让学生辨认这两句提问的共同结构。再追问：为什么仅仅把仪式做完，孔子仍然觉得不够？

    资料出处：《论语·八佾》。

    ### 课堂讨论
    【投影】
    今天有哪些看似合乎仪式、但缺少尊重的行为？

    【讲稿】
    给学生两分钟独立思考，然后请两位同学举例。
    """

    static func parse(_ source: String, defaultDestination: TeachingDestination) throws -> [TeachingDraft] {
        guard source.utf8.count <= 512 * 1024 else { throw TeachingOutlineError.tooLarge }
        var result: [TeachingDraft] = []
        var current = TeachingDraft(section: "", title: "未命名幻灯片")
        var lines: [String] = []
        var section = ""
        var destination = defaultDestination
        var currentHeadingLevel = 0
        var fence: String?

        func flushBlock() {
            let value = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { current.blocks.append(TeachingBlock(text: value, destination: destination)) }
            lines.removeAll(keepingCapacity: true)
        }
        func flushPage(suppressSectionHeading: Bool = false) {
            flushBlock()
            if (currentHeadingLevel != 0 && !(suppressSectionHeading && currentHeadingLevel == 2)) || !current.blocks.isEmpty {
                result.append(current)
            }
            current = TeachingDraft(section: section, title: section.isEmpty ? "未命名幻灯片" : section)
            currentHeadingLevel = 0
            destination = defaultDestination
        }

        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        for raw in normalized.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let active = fence {
                if line == active { fence = nil } else { lines.append(raw) }
                continue
            }
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                fence = String(line.prefix(3))
                continue
            }

            if let heading = heading(line) {
                if let (target, text) = marker(heading.title) {
                    flushBlock()
                    destination = target
                    if !text.isEmpty { lines.append(text) }
                    continue
                }
                flushPage(suppressSectionHeading: heading.level > 2)
                if heading.level <= 2 { section = heading.title }
                current = TeachingDraft(section: section, title: heading.title)
                currentHeadingLevel = heading.level
            } else if ["---", "***", "___"].contains(line) {
                flushPage()
            } else if let (target, text) = marker(line) {
                flushBlock()
                destination = target
                if !text.isEmpty { lines.append(text) }
            } else if line.isEmpty {
                flushBlock()
            } else {
                lines.append(displayLine(raw))
            }
            guard result.count <= 500 else { throw TeachingOutlineError.tooLarge }
        }
        flushPage()
        guard !result.isEmpty else { throw TeachingOutlineError.noContent }
        guard result.count <= 500 else { throw TeachingOutlineError.tooLarge }
        return result
    }

    private static func heading(_ line: String) -> (level: Int, title: String)? {
        let sigils = line.prefix { $0 == "#" }
        let level = sigils.count
        guard (1...6).contains(level), line.dropFirst(level).first?.isWhitespace == true else { return nil }
        let title = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : (level, title)
    }

    private static func marker(_ line: String) -> (TeachingDestination, String)? {
        let markers: [(TeachingDestination, [String])] = [
            (.notes, ["【讲稿】", "【教师讲稿】", "讲稿：", "讲稿:", "讲稿", "教师讲稿", "> [!NOTE]"]),
            (.projection, ["【投影】", "投影：", "投影:", "投影"])
        ]
        for (kind, names) in markers {
            if let name = names.first(where: { line == $0 || ($0.last?.isLetter == false && line.hasPrefix($0)) }) {
                return (kind, line.dropFirst(name.count).trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    private static func displayLine(_ raw: String) -> String {
        var line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("> ") { line = String(line.dropFirst(2)) }
        if ["- ", "* ", "+ "].contains(where: line.hasPrefix) { line = "• " + line.dropFirst(2) }
        return line
    }
}
