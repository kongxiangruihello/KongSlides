import Foundation

struct SlideConnector: Codable, Equatable {
    enum Arrow: String, Codable, CaseIterable {
        case none, triangle, arrow, stealth, diamond, oval

        var title: String {
            switch self {
            case .none: "无"
            case .triangle: "实心三角"
            case .arrow: "开放箭头"
            case .stealth: "燕尾箭头"
            case .diamond: "菱形"
            case .oval: "圆形"
            }
        }
    }

    enum Dash: String, Codable, CaseIterable {
        case solid, dash, dot, dashDot, lgDash, lgDashDot, lgDashDotDot, sysDash, sysDot, sysDashDot, sysDashDotDot

        var title: String {
            switch self {
            case .solid: "实线"
            case .dash, .sysDash: "虚线"
            case .dot, .sysDot: "点线"
            case .dashDot, .sysDashDot: "点划线"
            case .lgDash: "长虚线"
            case .lgDashDot: "长点划线"
            case .lgDashDotDot, .sysDashDotDot: "双点划线"
            }
        }

        var pattern: [CGFloat] {
            switch self {
            case .solid: []
            case .dash: [4, 3]
            case .dot: [1, 3]
            case .dashDot: [4, 3, 1, 3]
            case .lgDash: [8, 3]
            case .lgDashDot: [8, 3, 1, 3]
            case .lgDashDotDot: [8, 3, 1, 3, 1, 3]
            case .sysDash: [3, 1]
            case .sysDot: [1, 1]
            case .sysDashDot: [3, 1, 1, 1]
            case .sysDashDotDot: [3, 1, 1, 1, 1, 1]
            }
        }
    }

    struct Attachment: Codable, Equatable {
        enum Edge: Int, Codable, CaseIterable {
            case top = 0, left, bottom, right

            func point(in rect: CGRect) -> CGPoint {
                switch self {
                case .top: CGPoint(x: rect.midX, y: rect.minY)
                case .left: CGPoint(x: rect.minX, y: rect.midY)
                case .bottom: CGPoint(x: rect.midX, y: rect.maxY)
                case .right: CGPoint(x: rect.maxX, y: rect.midY)
                }
            }
        }

        let objectID: UUID
        let edge: Edge

        static func nearest(on target: SlideObject, to point: CGPoint) -> Self {
            let edge = Edge.allCases.min { left, right in
                let a = left.point(in: target.frame), b = right.point(in: target.frame)
                return hypot(a.x - point.x, a.y - point.y) < hypot(b.x - point.x, b.y - point.y)
            } ?? .top
            return Self(objectID: target.id, edge: edge)
        }
    }

    var startAttachment: Attachment?
    var endAttachment: Attachment?

    var startX = 0.0
    var startY = 0.5
    var endX = 1.0
    var endY = 0.5
    var weight = 2.0
    var startArrow: Arrow = .none
    var endArrow: Arrow = .none
    var dash: Dash = .solid

    var isValid: Bool {
        (0.25...96).contains(weight) &&
            [startX, startY, endX, endY].allSatisfy { (0...1).contains($0) } &&
            (startX != endX || startY != endY)
    }

    func endpoints(in rect: CGRect) -> (start: CGPoint, end: CGPoint) {
        (CGPoint(x: rect.minX + startX * rect.width, y: rect.minY + startY * rect.height),
         CGPoint(x: rect.minX + endX * rect.width, y: rect.minY + endY * rect.height))
    }

    static func object(from start: CGPoint, to end: CGPoint, style: Self = .init(), color: String = Palette.ink) -> SlideObject? {
        guard [start.x, start.y, end.x, end.y].allSatisfy({ abs($0) <= 20_000 }), start != end else { return nil }
        let width = max(16, abs(end.x - start.x))
        let height = max(16, abs(end.y - start.y))
        guard width <= 10_000, height <= 10_000 else { return nil }
        let x = (start.x + end.x - width) / 2
        let y = (start.y + end.y - height) / 2
        guard abs(x) <= 10_000, abs(y) <= 10_000 else { return nil }
        var line = style
        func ratio(_ coordinate: CGFloat, offset: CGFloat, extent: CGFloat) -> Double {
            Double(min(1, max(0, (coordinate - offset) / extent)))
        }
        line.startX = ratio(start.x, offset: x, extent: width)
        line.startY = ratio(start.y, offset: y, extent: height)
        line.endX = ratio(end.x, offset: x, extent: width)
        line.endY = ratio(end.y, offset: y, extent: height)
        guard line.isValid else { return nil }
        return SlideObject(kind: .connector, x: x, y: y, width: width, height: height,
                           color: color, connector: line)
    }
}


extension Slide {
    mutating func resolveConnectorAttachments() {
        guard objects.contains(where: { $0.connector?.startAttachment != nil || $0.connector?.endAttachment != nil }) else { return }
        let rectangles = Dictionary(objects.filter { $0.kind == .rectangle }.map { ($0.id, $0.frame) },
                                    uniquingKeysWith: { first, _ in first })
        for index in objects.indices {
            let object = objects[index]
            guard var line = object.connector, line.startAttachment != nil || line.endAttachment != nil else { continue }
            var ends = line.endpoints(in: object.frame)
            func connection(_ attachment: SlideConnector.Attachment?) -> CGPoint? {
                guard let attachment, let frame = rectangles[attachment.objectID] else { return nil }
                return attachment.edge.point(in: frame)
            }
            if let start = connection(line.startAttachment) { ends.start = start }
            else { line.startAttachment = nil }
            if let end = connection(line.endAttachment) { ends.end = end }
            else { line.endAttachment = nil }

            if let resized = SlideConnector.object(from: ends.start, to: ends.end, style: line, color: object.color) {
                objects[index].x = resized.x
                objects[index].y = resized.y
                objects[index].width = resized.width
                objects[index].height = resized.height
                objects[index].connector = resized.connector
            } else {
                objects[index].connector = line
            }
        }
    }
}
