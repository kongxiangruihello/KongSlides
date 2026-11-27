import AppKit
import ApplicationServices

guard CommandLine.arguments.count > 2, let pid = Int32(CommandLine.arguments[1]) else { exit(2) }
guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
    fputs("Mouse verification unavailable: macOS did not grant Accessibility and event posting access.\n", stderr)
    exit(77)
}
let app = AXUIElementCreateApplication(pid)

func attribute(_ item: AXUIElement, _ key: CFString) -> CFTypeRef? {
    var result: CFTypeRef?
    return AXUIElementCopyAttributeValue(item, key, &result) == .success ? result : nil
}

func find(_ identifier: String) -> AXUIElement? {
    var queue = [app]
    var index = 0
    while index < queue.count && index < 5000 {
        let item = queue[index]
        index += 1
        if attribute(item, kAXIdentifierAttribute as CFString) as? String == identifier { return item }
        queue += attribute(item, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []
    }
    return nil
}

func waitFor(_ identifier: String) -> AXUIElement? {
    for _ in 0..<40 {
        if let result = find(identifier) { return result }
        Thread.sleep(forTimeInterval: 0.1)
    }
    return nil
}

func click(_ id: String, x: CGFloat, y: CGFloat) {
    guard let thumbnail = waitFor("slide-thumbnail-" + id),
          let pointValue = attribute(thumbnail, kAXPositionAttribute as CFString),
          let sizeValue = attribute(thumbnail, kAXSizeAttribute as CFString),
          CFGetTypeID(pointValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
        fputs("Could not locate thumbnail \(id)\n", stderr)
        exit(1)
    }
    var origin = CGPoint.zero, size = CGSize.zero
    guard AXValueGetValue(pointValue as! AXValue, .cgPoint, &origin),
          AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
          size.width > 0, size.height > 0 else { exit(1) }
    let point = CGPoint(x: origin.x + size.width * x, y: origin.y + size.height * y)
    for kind: CGEventType in [.mouseMoved, .leftMouseDown, .leftMouseUp] {
        CGEvent(mouseEventSource: nil, mouseType: kind, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }
    guard waitFor("editor-canvas-" + id) != nil, waitFor("editor-notes-" + id) != nil else {
        fputs("Canvas and speaker notes did not both follow the clicked thumbnail \(id)\n", stderr)
        exit(1)
    }
}

if let running = NSRunningApplication(processIdentifier: pid) { _ = running.activate(options: []) }
let pages = Array(CommandLine.arguments.dropFirst(2))
for (index, page) in pages.enumerated() {
    let locations: [(CGFloat, CGFloat)] = [(0.45, 0.35), (0.45, 0.90), (0.94, 0.92)]
    let position = locations[index % locations.count]
    click(page, x: position.0, y: position.1)
}
print("Desktop mouse clicks followed the correct canvas and notes on \(pages.count) clicks")
