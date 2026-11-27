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

func find(_ root: AXUIElement, _ predicate: (AXUIElement) -> Bool) -> AXUIElement? {
    var queue = [root]
    var index = 0
    while index < queue.count && index < 700 {
        let item = queue[index]
        index += 1
        if predicate(item) { return item }
        queue += get(item, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }
    return nil
}

func located(_ title: String, from root: AXUIElement = app) -> AXUIElement? {
    find(root) { item in
        [kAXTitleAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute].contains { get(item, $0) as? String == title }
    }
}

func awaitElement(_ title: String, _ lookup: () -> AXUIElement?) -> AXUIElement {
    for _ in 0..<60 {
        if let found = lookup() { return found }
        Thread.sleep(forTimeInterval: 0.15)
    }
    fputs("Missing \(title)\n", stderr)
    exit(1)
}

func click(_ item: AXUIElement) {
    guard let location = get(item, kAXPositionAttribute), let dimensions = get(item, kAXSizeAttribute),
          CFGetTypeID(location) == AXValueGetTypeID(), CFGetTypeID(dimensions) == AXValueGetTypeID() else {
        fputs("Unable to get bounds for click\n", stderr)
        exit(3)
    }
    var origin = CGPoint.zero
    var size = CGSize.zero
    AXValueGetValue(location as! AXValue, .cgPoint, &origin)
    AXValueGetValue(dimensions as! AXValue, .cgSize, &size)
    let point = CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
    for kind: CGEventType in [.mouseMoved, .leftMouseDown, .leftMouseUp] {
        CGEvent(mouseEventSource: nil, mouseType: kind, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }
    Thread.sleep(forTimeInterval: 0.2)
}

func key(_ code: CGKeyCode, flags: CGEventFlags = []) {
    for pressed in [true, false] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: pressed)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }
    Thread.sleep(forTimeInterval: 0.2)
}

func sheet() -> AXUIElement? {
    find(app) { get($0, kAXRoleAttribute) as? String == kAXSheetRole }
}

_ = awaitElement("导入") { located("import-menu") ?? located("导入") }
_ = awaitElement("导出") { located("export-menu") ?? located("导出") }
_ = awaitElement("属性") { located("toggle-inspector-panel") }
click(awaitElement("文本框") { located("insert-text-box") })
_ = awaitElement("嵌入式文字编辑器") { located("编辑幻灯片文本") }
click(awaitElement("编号") { located("编号") })
print("Editor toolbar exposes Import, Export and Properties, and the numbering button was clicked on a text object.")
key(53)
key(1, flags: [.maskCommand, .maskShift])
let dialog = awaitElement("Save As sheet") { sheet() }
let formats = awaitElement("保存格式") {
    located("保存格式", from: dialog) ?? find(dialog) { item in
        get(item, kAXRoleAttribute) as? String == kAXPopUpButtonRole &&
            (get(item, kAXValueAttribute) as? String)?.contains("KongSlides") == true
    }
}
click(formats)
if let pptx = located("PowerPoint 演示文稿（.pptx）") {
    if AXUIElementPerformAction(pptx, kAXPressAction as CFString) != .success {
        key(125)
        key(36)
    }
} else {
    key(125)
    key(36)
}
_ = awaitElement("PPTX selected") {
    ((get(formats, kAXValueAttribute) as? String)?.contains("PowerPoint") == true ||
        (get(formats, kAXTitleAttribute) as? String)?.contains("PowerPoint") == true) ? formats : nil
}
let save = awaitElement("Save button") { located("保存", from: dialog) ?? located("Save", from: dialog) }
let status = AXUIElementPerformAction(save, kAXPressAction as CFString)
if status != .success, sheet() != nil { click(save) }
print("PowerPoint was selected in the Save As sheet and Save was pressed.")
