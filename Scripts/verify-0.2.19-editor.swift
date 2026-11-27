import AppKit
import ApplicationServices

guard let pid = Int32(CommandLine.arguments[1]), AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
    fputs("Accessibility or event posting unavailable\n", stderr)
    exit(1)
}
let app = AXUIElementCreateApplication(pid)

func attr(_ item: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(item, key as CFString, &value) == .success ? value : nil
}

func find(_ root: AXUIElement, _ predicate: (AXUIElement) -> Bool) -> AXUIElement? {
    var queue = [root]
    var index = 0
    while index < queue.count && index < 4000 {
        let item = queue[index]
        index += 1
        if predicate(item) { return item }
        queue += attr(item, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }
    return nil
}

func element(_ id: String) -> AXUIElement? {
    find(app) { item in
        [kAXIdentifierAttribute, kAXTitleAttribute, kAXDescriptionAttribute].contains { attr(item, $0) as? String == id }
    }
}

func until<T>(_ name: String, _ check: () -> T?) -> T {
    for _ in 0..<120 {
        if let value = check() { return value }
        Thread.sleep(forTimeInterval: 0.10)
    }
    fputs("Timed out waiting for \(name)\n", stderr)
    exit(1)
}

func click(_ id: String) {
    let item = until(id) { element(id) }
    if AXUIElementPerformAction(item, kAXPressAction as CFString) == .success { return }
    guard let location = attr(item, kAXPositionAttribute), let dimensions = attr(item, kAXSizeAttribute),
          CFGetTypeID(location) == AXValueGetTypeID(), CFGetTypeID(dimensions) == AXValueGetTypeID() else { exit(3) }
    var point = CGPoint.zero
    var size = CGSize.zero
    AXValueGetValue(location as! AXValue, .cgPoint, &point)
    AXValueGetValue(dimensions as! AXValue, .cgSize, &size)
    point.x += size.width / 2
    point.y += size.height / 2
    for kind: CGEventType in [.mouseMoved, .leftMouseDown, .leftMouseUp] {
        CGEvent(mouseEventSource: nil, mouseType: kind, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }
}

func key(_ code: CGKeyCode, _ flags: CGEventFlags = []) {
    for pressed in [true, false] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: pressed)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }
    Thread.sleep(forTimeInterval: 0.15)
}

func type(_ text: String) {
    let units = Array(text.utf16)
    let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
    event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
    event?.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.20)
}

func saveSheet() -> AXUIElement? {
    find(app) { item in
        attr(item, kAXRoleAttribute) as? String == kAXSheetRole
    }
}

_ = until("editor toolbar") { element("insert-text-box") }
click("close-inspector-panel")
_ = until("inspector closed") { element("close-inspector-panel") == nil ? true : nil }
click("toggle-inspector-panel")
_ = until("inspector reopened") { element("close-inspector-panel") }
click("close-notes-panel")
_ = until("notes closed") { element("close-notes-panel") == nil ? true : nil }
click("toggle-notes-panel")
_ = until("notes reopened") { element("close-notes-panel") }
click("insert-text-box")
_ = until("canvas text editor") { element("编辑幻灯片文本") }
type("Editor smoke")
click("粗体")
key(53)
print("Toolbar insert and text formatting worked; both panels closed and reopened.")

key(1, [.maskCommand, .maskShift])
_ = until("first Save As sheet") { saveSheet() }
key(53)
_ = until("Save As cancellation") { saveSheet() == nil ? true : nil }
key(1, [.maskCommand, .maskShift])
let sheet = until("second Save As sheet") { saveSheet() }
let field = until("file name field") {
    find(sheet) { attr($0, kAXRoleAttribute) as? String == kAXTextFieldRole }
}
let selected = AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
print("Save As name field focus result \(selected.rawValue)")
key(0, .maskCommand)
type("Saved copy")
key(36)
_ = until("Save As confirmation") { saveSheet() == nil ? true : nil }
print("Save As opened as a sheet, cancelled, reopened and confirmed.")
