import AppKit
import ApplicationServices

guard let pid = Int32(CommandLine.arguments[1]), AXIsProcessTrusted(), CGPreflightPostEventAccess() else { exit(1) }
let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 1)
setbuf(stdout, nil)

func get(_ item: AXUIElement, _ key: String) -> CFTypeRef? {
    var result: CFTypeRef?
    return AXUIElementCopyAttributeValue(item, key as CFString, &result) == .success ? result : nil
}

func label(_ name: String) -> AXUIElement? {
    var queue = [app]
    var index = 0
    while index < queue.count && index < 800 {
        let item = queue[index]
        index += 1
        if [kAXTitleAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute, kAXValueAttribute].contains(where: {
            get(item, $0) as? String == name
        }) { return item }
        queue += get(item, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }
    return nil
}

func until<T>(_ description: String, _ probe: () -> T?) -> T {
    for _ in 0..<75 {
        if let result = probe() { return result }
        Thread.sleep(forTimeInterval: 0.12)
    }
    fputs("Did not find " + description + "\n", stderr)
    exit(2)
}

func bounds(_ item: AXUIElement) -> CGRect? {
    guard let pos = get(item, kAXPositionAttribute), let size = get(item, kAXSizeAttribute),
          CFGetTypeID(pos) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
    var origin = CGPoint.zero, dimensions = CGSize.zero
    AXValueGetValue(pos as! AXValue, .cgPoint, &origin)
    AXValueGetValue(size as! AXValue, .cgSize, &dimensions)
    return CGRect(origin: origin, size: dimensions)
}

func click(_ item: AXUIElement) {
    guard let frame = bounds(item) else { exit(3) }
    let point = CGPoint(x: frame.midX, y: frame.midY)
    for event in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
        CGEvent(mouseEventSource: nil, mouseType: event, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }
    Thread.sleep(forTimeInterval: 0.24)
}

func key(_ code: CGKeyCode, _ flags: CGEventFlags = []) {
    for pressed in [true, false] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: pressed)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }
    Thread.sleep(forTimeInterval: 0.25)
}

func expectPage(_ index: Int) {
    let id = String(format: "00000000-0000-4000-8000-%012d", index)
    _ = until("canvas for page \(index)") { label("editor-canvas-" + id) }
    _ = until("notes for page \(index)") { label("editor-notes-" + id) }
    _ = until("page status for page \(index)") { label("第 \(index)/94 页") }
    print("Page \(index) matched in canvas, notes and status.")
}

let window = until("editor window") { (get(app, kAXWindowsAttribute) as? [AXUIElement])?.first }
let display = CGDisplayBounds(CGMainDisplayID())
var size = CGSize(width: 1040, height: 680)
if let value = AXValueCreate(.cgSize, &size) {
    AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
}
let width = bounds(window)?.width ?? 1040
var origin = CGPoint(x: display.minX + min(8, display.width - width - 9), y: display.minY + 32)
if let pos = AXValueCreate(.cgPoint, &origin) {
    AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pos)
}
expectPage(1)
for name in ["insert-text-box", "项目符号", "编号", "字体", "字号", "文字颜色", "对齐", "更多格式"] {
    _ = until("toolbar " + name) { label(name) }
}
let second = "00000000-0000-4000-8000-000000000002"
click(until("second thumbnail") { label("slide-thumbnail-" + second) })
expectPage(2)
key(125)
expectPage(3)
click(until("close inspector") { label("close-inspector-panel") })
_ = until("inspector closed") { label("close-inspector-panel") == nil ? true : nil }
click(until("restore inspector") { label("toggle-inspector-panel") })
_ = until("inspector reopened") { label("close-inspector-panel") }
click(until("100% zoom") { label("100%") })
click(until("fit window") { label("适合窗口") })
key(1, .maskCommand)
_ = until("file receipt") { label("export-result") }
_ = until("reveal in Finder") { label("在 Finder 中显示") }
print("Narrow toolbar, pane reopening, zoom controls and save result verified.")
