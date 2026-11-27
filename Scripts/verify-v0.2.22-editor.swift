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

func scan(_ root: AXUIElement, _ test: (AXUIElement) -> Bool) -> AXUIElement? {
    var queue = [root]
    var index = 0
    while index < queue.count && index < 600 {
        let item = queue[index]
        index += 1
        if test(item) { return item }
        queue += get(item, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }
    return nil
}

func label(_ name: String, role: String? = nil, from root: AXUIElement = app) -> AXUIElement? {
    scan(root) { item in
        if let role, get(item, kAXRoleAttribute) as? String != role { return false }
        return [kAXTitleAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute, kAXPlaceholderValueAttribute].contains {
            get(item, $0) as? String == name
        }
    }
}

func until<T>(_ description: String, _ probe: () -> T?) -> T {
    for _ in 0..<65 {
        if let result = probe() { return result }
        Thread.sleep(forTimeInterval: 0.12)
    }
    fputs("Did not find " + description + "\n", stderr)
    exit(2)
}

func click(_ item: AXUIElement) {
    guard let pos = get(item, kAXPositionAttribute), let size = get(item, kAXSizeAttribute),
          CFGetTypeID(pos) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { exit(3) }
    var point = CGPoint.zero, dimensions = CGSize.zero
    AXValueGetValue(pos as! AXValue, .cgPoint, &point)
    AXValueGetValue(size as! AXValue, .cgSize, &dimensions)
    point.x += dimensions.width / 2
    point.y += dimensions.height / 2
    for event in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
        CGEvent(mouseEventSource: nil, mouseType: event, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }
    Thread.sleep(forTimeInterval: 0.3)
}

func key(_ code: CGKeyCode, _ flags: CGEventFlags = []) {
    for pressed in [true, false] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: pressed)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }
    Thread.sleep(forTimeInterval: 0.25)
}

func type(_ text: String) {
    let units = Array(text.utf16)
    let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
    event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
    event?.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.25)
}

func sheet() -> AXUIElement? { scan(app) { get($0, kAXRoleAttribute) as? String == kAXSheetRole } }

let window = until("editor window") { (get(app, kAXWindowsAttribute) as? [AXUIElement])?.first }
let display = CGDisplayBounds(CGMainDisplayID())
var width: CGFloat = 1040
if let size = get(window, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() {
    var dimensions = CGSize.zero
    AXValueGetValue(size as! AXValue, .cgSize, &dimensions)
    width = dimensions.width
}
var origin = CGPoint(x: display.minX + min(15, display.width - width - 12), y: display.minY + 30)
if let pos = AXValueCreate(.cgPoint, &origin) {
    AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pos)
}
_ = until("slide canvas") { label("editor-canvas-4BF6459E-819C-440E-A535-29DE239F51B1") ?? label("insert-text-box") }
let more = until("More toolbar menu") { label("更多") }
click(more)
let replace = until("Find and Replace menu item") { label("查找与替换…", role: kAXMenuItemRole) ?? label("查找与替换…") }
if AXUIElementPerformAction(replace, kAXPressAction as CFString) != .success { click(replace) }
let lookup = until("Replace sheet") { sheet() }
let query = until("Find text") { label("查找文字", from: lookup) }
click(query)
type("Old")
let replacement = until("Replacement text") { label("替换为（留空即删除）", from: lookup) }
click(replacement)
type("New")
click(until("Preview matches") { label("预览匹配项", from: lookup) })
click(until("Replace selected") { label("替换所选", from: lookup) })
_ = until("Replace sheet closed") { sheet() == nil ? true : nil }
key(1, .maskCommand)
print("Edited an actual deck through the scoped Replace sheet and saved it.")
key(1, [.maskCommand, .maskShift])
let format = until("PowerPoint format button") {
    sheet().flatMap { label("PowerPoint 演示文稿（.pptx）", role: kAXButtonRole, from: $0) }
}
click(format)
let save = until("Save PPTX") {
    sheet().flatMap { label("保存", role: kAXButtonRole, from: $0) ?? label("Save", role: kAXButtonRole, from: $0) }
}
click(save)
_ = until("PPTX dialog closed") { sheet() == nil ? true : nil }
print("Saved the edited file as PPTX through the native format chooser.")
