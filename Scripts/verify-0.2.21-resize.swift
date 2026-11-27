import AppKit
import ApplicationServices

guard let pid = Int32(CommandLine.arguments[1]), AXIsProcessTrusted(), CGPreflightPostEventAccess() else { exit(1) }
let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 1)
setbuf(stdout, nil)

func attribute(_ node: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(node, key as CFString, &value) == .success ? value : nil
}

func find(_ identifier: String) -> AXUIElement? {
    var nodes = [app]
    var cursor = 0
    while cursor < nodes.count && cursor < 600 {
        let node = nodes[cursor]
        cursor += 1
        if attribute(node, kAXIdentifierAttribute) as? String == identifier { return node }
        nodes += attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }
    return nil
}

func bounds(_ node: AXUIElement) -> CGRect? {
    guard let pos = attribute(node, kAXPositionAttribute), let dim = attribute(node, kAXSizeAttribute),
          CFGetTypeID(pos) == AXValueGetTypeID(), CFGetTypeID(dim) == AXValueGetTypeID() else { return nil }
    var origin = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(pos as! AXValue, .cgPoint, &origin),
          AXValueGetValue(dim as! AXValue, .cgSize, &size), size.width > 0, size.height > 0 else { return nil }
    return CGRect(origin: origin, size: size)
}

func until<T>(_ message: String, _ probe: () -> T?) -> T {
    for _ in 0..<65 {
        if let result = probe() { return result }
        Thread.sleep(forTimeInterval: 0.15)
    }
    fputs(message + "\n", stderr)
    exit(1)
}

func event(_ type: CGEventType, _ point: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.05)
}

@discardableResult
func move(_ identifier: String, by offset: CGFloat) -> CGFloat {
    let start = until("Missing " + identifier) { find(identifier).flatMap(bounds) }
    let center = CGPoint(x: start.midX, y: start.midY)
    print("Before drag \(identifier): \(start), intended delta \(offset)")
    if let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] {
        print("Window bounds:", windows.compactMap(bounds))
    }
    event(.mouseMoved, center)
    event(.leftMouseDown, center)
    for step in 1...8 {
        event(.leftMouseDragged, CGPoint(x: center.x + offset * CGFloat(step) / 8, y: center.y))
    }
    event(.leftMouseUp, CGPoint(x: center.x + offset, y: center.y))
    Thread.sleep(forTimeInterval: 0.5)
    print("After drag \(identifier):", find(identifier).flatMap(bounds) as Any)
    print("Mouse location:", NSEvent.mouseLocation)
    let final = until("Divider did not move by \(offset): \(identifier)") {
        guard let position = find(identifier).flatMap(bounds), abs(position.midX - start.midX - offset) < 5 else { return nil as CGRect? }
        return position
    }
    print("\(identifier) moved from \(start.midX) to \(final.midX)")
    return final.midX
}

let appWindow = until("Missing editor window") {
    (attribute(app, kAXWindowsAttribute) as? [AXUIElement])?.first
}
let display = CGDisplayBounds(CGMainDisplayID())
print("Desktop display bounds:", display)
var origin = CGPoint(x: display.minX + 15, y: display.minY + 30)
if let position = AXValueCreate(.cgPoint, &origin) {
    print("Positioned test window on the main display:",
          AXUIElementSetAttributeValue(appWindow, kAXPositionAttribute as CFString, position).rawValue)
}
Thread.sleep(forTimeInterval: 0.5)
move("resize-slide-sidebar", by: 75)
move("resize-layout-inspector", by: -65)
move("resize-slide-sidebar", by: -30)
let inspector = move("resize-layout-inspector", by: 25)
for identifier in ["close-inspector-panel", "toggle-inspector-panel"] {
    let button = until("Missing " + identifier) { find(identifier).flatMap(bounds) }
    let point = CGPoint(x: button.midX, y: button.midY)
    for kind: CGEventType in [.mouseMoved, .leftMouseDown, .leftMouseUp] { event(kind, point) }
    if identifier == "close-inspector-panel" {
        _ = until("Inspector remained visible") { find("resize-layout-inspector") == nil ? true : nil }
    }
}
let restored = until("Inspector width was not restored after reopening") {
    guard let position = find("resize-layout-inspector").flatMap(bounds), abs(position.midX - inspector) < 1 else { return nil as CGRect? }
    return position
}
print("Inspector reopened at the dragged position \(restored.midX).")
