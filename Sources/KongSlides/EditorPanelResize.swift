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

struct EditorPanelResizeHandle: View {
    let title: String
    let identifier: String
    let translation: GestureState<Double>
    let resize: (Double) -> Void
    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(hovering || translation.wrappedValue != 0 ? Color.accentColor : Color(nsColor: .separatorColor))
            .frame(width: hovering || translation.wrappedValue != 0 ? 2 : 1)
            .frame(width: EditorPanelWidths.dividerWidth)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .help(title)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .updating(translation) { value, live, _ in live = value.translation.width }
                .onEnded { value in
                    if value.translation.width != 0 { resize(value.translation.width) }
                })
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
            }
            .onDisappear {
                if hovering { NSCursor.arrow.set() }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityIdentifier(identifier)
    }
}
