import AppKit
import SwiftUI

struct EditorPanelWidths {
    enum Side {
        case left, right

        var limits: ClosedRange<Double> {
            switch self {
            case .left: 168...360
            case .right: 210...400
            }
        }

        func widthChange(for translation: Double) -> Double { self == .left ? translation : -translation }

        func clamp(_ width: Double) -> Double { min(limits.upperBound, max(limits.lowerBound, width)) }
    }

    static let dividerWidth = 10.0
    static let minimumWorkspaceWidth = 420.0

    let left: Double
    let right: Double
    private let available: Double

    init(windowWidth: Double, preferredLeft: Double, preferredRight: Double?) {
        let left = Side.left.clamp(preferredLeft)
        let right = preferredRight.map(Side.right.clamp) ?? 0
        let minimumLeft = Side.left.limits.lowerBound
        let minimumRight = preferredRight == nil ? 0 : Side.right.limits.lowerBound
        available = max(minimumLeft + minimumRight,
                        windowWidth - Self.minimumWorkspaceWidth - Self.dividerWidth * (right > 0 ? 2 : 1))
        let fittedLeft = min(left, available - minimumRight)
        self.left = fittedLeft
        self.right = min(right, available - fittedLeft)
    }

    func width(_ side: Side, translation: Double) -> Double {
        let initial = side == .left ? left : right
        guard initial > 0 else { return 0 }
        let opposite = side == .left ? right : left
        return side.clamp(min(available - opposite, initial + side.widthChange(for: translation)))
    }
}

struct EditorPanelResizeHandle: NSViewRepresentable {
    let title: String
    let identifier: String
    @Binding var translation: Double
    let resize: (Double) -> Void

    func makeNSView(context: Context) -> DividerView {
        let view = DividerView()
        view.toolTip = title
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.splitter)
        view.setAccessibilityLabel(title)
        view.setAccessibilityIdentifier(identifier)
        return view
    }

    func updateNSView(_ view: DividerView, context: Context) {
        view.onDrag = { translation = $0 }
        view.onCommit = { offset in
            if offset != 0 { resize(offset) }
            translation = 0
        }
    }

    final class DividerView: NSView {
        var onDrag: ((Double) -> Void)?
        var onCommit: ((Double) -> Void)?
        private var startX: CGFloat?
        private var hovering = false
        private var tracking: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            tracking = area
        }

        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        override func mouseEntered(with event: NSEvent) {
            hovering = true
            needsDisplay = true
        }

        override func mouseExited(with event: NSEvent) {
            hovering = false
            needsDisplay = true
        }

        override func mouseDown(with event: NSEvent) {
            startX = event.locationInWindow.x
            needsDisplay = true
        }

        override func mouseDragged(with event: NSEvent) {
            guard let startX else { return }
            onDrag?(event.locationInWindow.x - startX)
        }

        override func mouseUp(with event: NSEvent) {
            guard let startX else { return }
            self.startX = nil
            hovering = bounds.contains(convert(event.locationInWindow, from: nil))
            onCommit?(event.locationInWindow.x - startX)
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            let active = hovering || startX != nil
            let thickness: CGFloat = active ? 2 : 1
            (active ? NSColor.controlAccentColor : .separatorColor).setFill()
            NSBezierPath(rect: NSRect(x: bounds.midX - thickness / 2, y: bounds.minY,
                                      width: thickness, height: bounds.height)).fill()
        }
    }
}
