import AppKit

@MainActor
public final class UpdateProgressPanel {
    private let window: NSPanel
    private let label: NSTextField
    private let indicator = NSProgressIndicator()

    public init(title: String) {
        label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        let bounds = CGRect(x: 0, y: 0, width: 420, height: 100)
        window = NSPanel(contentRect: bounds, styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.isFloatingPanel = true
        let content = NSView(frame: bounds)
        label.frame = CGRect(x: 24, y: 59, width: 372, height: 19)
        indicator.frame = CGRect(x: 24, y: 29, width: 372, height: 16)
        indicator.style = .bar
        indicator.minValue = 0
        indicator.maxValue = 1
        indicator.usesThreadedAnimation = true
        content.addSubview(label)
        content.addSubview(indicator)
        window.contentView = content
        window.center()
    }

    public func show(_ phase: String, fraction: Double? = nil) {
        label.stringValue = phase
        indicator.setAccessibilityLabel(phase)
        indicator.isIndeterminate = fraction == nil
        if let fraction {
            indicator.doubleValue = min(1, max(0, fraction))
        } else {
            indicator.startAnimation(nil)
        }
        if !window.isVisible { window.orderFrontRegardless() }
    }

    public func dismiss() {
        indicator.stopAnimation(nil)
        window.orderOut(nil)
    }
}
