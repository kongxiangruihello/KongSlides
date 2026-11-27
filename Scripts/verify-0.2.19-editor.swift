import AppKit
import ApplicationServices

guard let pid = Int32(CommandLine.arguments[1]), AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
    fputs("Accessibility or event posting unavailable\n", stderr)
    exit(1)
}
let app = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(app, 1)
setbuf(stdout, nil)
if let running = NSRunningApplication(processIdentifier: pid) { running.activate() }

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

func dump(_ item: AXUIElement, depth: Int = 0) {
    guard depth < 9 else { return }
    let facts = [kAXRoleAttribute, kAXIdentifierAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
                 kAXValueAttribute, kAXEnabledAttribute].compactMap { attr(item, $0) }.map { String(describing: $0) }
    fputs(String(repeating: " ", count: depth) + facts.joined(separator: " | ") + "\n", stderr)
    for child in (attr(item, kAXChildrenAttribute) as? [AXUIElement] ?? []).prefix(30) {
        dump(child, depth: depth + 1)
    }
}

func until<T>(_ name: String, _ check: () -> T?) -> T {
    for _ in 0..<120 {
        if let value = check() { return value }
        Thread.sleep(forTimeInterval: 0.10)
    }
    fputs("Timed out waiting for \(name)\n", stderr)
    if let sheet = saveSheet() { dump(sheet) }
    exit(1)
}

func click(_ id: String) {
    print("Clicking \(id)")
    _ = until(id) {
        guard let item = element(id) else { return nil as Bool? }
        if AXUIElementPerformAction(item, kAXPressAction as CFString) == .success { return true }
        guard let location = attr(item, kAXPositionAttribute), let dimensions = attr(item, kAXSizeAttribute),
              CFGetTypeID(location) == AXValueGetTypeID(), CFGetTypeID(dimensions) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(location as! AXValue, .cgPoint, &point),
              AXValueGetValue(dimensions as! AXValue, .cgSize, &size), size.width > 0, size.height > 0 else { return nil }
        point.x += size.width / 2
        point.y += size.height / 2
        for kind: CGEventType in [.mouseMoved, .leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: kind, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        return true
    }
    Thread.sleep(forTimeInterval: 0.25)
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
key(1, [.maskCommand, .maskShift])
_ = until("first Save As sheet") { saveSheet() }
key(53)
_ = until("Save As cancellation") { saveSheet() == nil ? true : nil }
key(1, [.maskCommand, .maskShift])
let sheet = until("second Save As sheet") { saveSheet() }
let save = until("Save Button") {
    find(sheet) { item in
        let title = attr(item, kAXTitleAttribute) as? String
        return attr(item, kAXRoleAttribute) as? String == kAXButtonRole && (title == "保存" || title == "Save")
    }
}
let result = AXUIElementPerformAction(save, kAXPressAction as CFString)
print("Clicked Save, accessibility response: \(result.rawValue)")
if result != .success {
    if element("保存") != nil { click("保存") } else { click("Save") }
}
_ = until("Save As sheet dismissed after confirmation") { saveSheet() == nil ? true : nil }
print("Imported PowerPoint Save As opened, cancelled and then completed through the native Save button.")
