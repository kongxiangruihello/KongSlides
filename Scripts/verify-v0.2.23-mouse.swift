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
        if attribute(item, kAXIdentifierAttribute as CFString) as? String == identifier ||
            attribute(item, kAXTitleAttribute as CFString) as? String == identifier ||
            attribute(item, kAXDescriptionAttribute as CFString) as? String == identifier { return item }
        queue += attribute(item, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []
    }
    return nil
}

func waitFor(_ identifier: String) -> AXUIElement? {
    for _ in 0..<100 {
        if let result = find(identifier) { return result }
        Thread.sleep(forTimeInterval: 0.1)
    }
    return nil
}

func boundsOf(_ item: AXUIElement) -> CGRect? {
    guard let position = attribute(item, kAXPositionAttribute as CFString),
          let dimensions = attribute(item, kAXSizeAttribute as CFString),
          CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(dimensions) == AXValueGetTypeID() else { return nil }
    var origin = CGPoint.zero, size = CGSize.zero
    guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
          AXValueGetValue(dimensions as! AXValue, .cgSize, &size), size.width > 0, size.height > 0 else { return nil }
    return CGRect(origin: origin, size: size)
}

func fail(_ message: String) -> Never {
    fputs(message + "\n", stderr)
    exit(1)
}

func clickElement(_ identifier: String, x: CGFloat = 0.5, y: CGFloat = 0.5) {
    guard let element = waitFor(identifier), let bounds = boundsOf(element) else { fail("Could not locate " + identifier) }
    let point = CGPoint(x: bounds.minX + bounds.width * x, y: bounds.minY + bounds.height * y)
    for kind: CGEventType in [.mouseMoved, .leftMouseDown, .leftMouseUp] {
        CGEvent(mouseEventSource: nil, mouseType: kind, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }
}

func revealClickPoint(_ identifier: String, x: CGFloat, y: CGFloat) {
    guard let list = waitFor("sidebar-list"), let area = boundsOf(list) else { fail("Could not locate sidebar viewport") }
    let visible = area.insetBy(dx: 1, dy: 5)
    for _ in 0..<20 {
        guard let item = find(identifier), let bounds = boundsOf(item) else { fail("Could not locate " + identifier) }
        let point = CGPoint(x: bounds.minX + bounds.width * x, y: bounds.minY + bounds.height * y)
        if visible.contains(point) {
            print("Thumbnail mouse point visible: \(identifier) at \(point), sidebar \(area)")
            return
        }
        let mouse = CGPoint(x: area.midX, y: area.midY)
        let amount = point.y > visible.maxY ? -70 : 70
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                            wheel1: Int32(amount), wheel2: 0, wheel3: 0)
        event?.location = mouse
        event?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.18)
    }
    fail("Could not make the requested thumbnail click point visible: " + identifier)
}

func click(_ id: String, x: CGFloat, y: CGFloat) {
    let identifier = "slide-thumbnail-" + id
    revealClickPoint(identifier, x: x, y: y)
    clickElement(identifier, x: x, y: y)
    guard waitFor("editor-canvas-" + id) != nil, waitFor("editor-notes-" + id) != nil else {
        fputs("Canvas and speaker notes did not both follow the clicked thumbnail \(id)\n", stderr)
        exit(1)
    }
}

func scrollTo(_ id: String, down: Bool) {
    guard let list = waitFor("sidebar-list"), let area = boundsOf(list) else { fail("Could not locate sidebar viewport") }
    let key = "slide-thumbnail-" + id
    for _ in 0..<32 {
        if let target = find(key), let bounds = boundsOf(target),
           area.insetBy(dx: 1, dy: 12).contains(CGPoint(x: bounds.midX, y: bounds.midY)) { return }
        let point = CGPoint(x: area.midX, y: area.midY)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        let scroll = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                             wheel1: down ? -280 : 280, wheel2: 0, wheel3: 0)
        scroll?.location = point
        scroll?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.15)
    }
    fail("Could not scroll thumbnail into view: " + id)
}

func key(_ code: CGKeyCode, flags: CGEventFlags = []) {
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }
}

if let running = NSRunningApplication(processIdentifier: pid) { _ = running.activate(options: []) }
let pages = Array(CommandLine.arguments.dropFirst(2))
func homeVisible() -> Bool {
    for _ in 0..<100 {
        if find("kongslides-home-search") != nil || find("新建课件") != nil || find("搜索收藏和最近打开的课件") != nil { return true }
        Thread.sleep(forTimeInterval: 0.1)
    }
    return false
}
func dumpAccessibility() {
    var pending = [app]
    for _ in 0..<150 {
        guard !pending.isEmpty else { break }
        let element = pending.removeFirst()
        let keys = [kAXRoleAttribute, kAXIdentifierAttribute, kAXTitleAttribute, kAXDescriptionAttribute]
        print(keys.compactMap { attribute(element, $0 as CFString) as? String }.joined(separator: " | "))
        pending += attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []
    }
}
if pages == ["--home"] {
    guard homeVisible() else { dumpAccessibility(); fail("Home did not appear after launch") }
    print("Desktop startup reached the KongSlides home.")
    exit(0)
}
if pages == ["--home-roundtrip"] {
    clickElement("返回首页")
    guard homeVisible() else { dumpAccessibility(); fail("Editor did not return to home") }
    guard waitFor("收藏 Second") != nil else { dumpAccessibility(); fail("Recently opened file is missing from home") }
    clickElement("收藏 Second")
    guard waitFor("移除收藏 Second") != nil else { fail("Favorite did not update") }
    clickElement("继续编辑")
    guard waitFor("editor-canvas-4BF6459E-819C-440E-A535-29DE239F51B1") != nil else { fail("Continue did not reopen the active edit view") }
    clickElement("返回首页")
    guard waitFor("接着备课") != nil else { dumpAccessibility(); fail("Resume card did not appear") }
    clickElement("接着备课")
    guard waitFor("editor-canvas-4BF6459E-819C-440E-A535-29DE239F51B1") != nil else { fail("Resume card did not return to editing") }
    print("Desktop home showed recent files, added a favorite, and opened the resume card.")
    exit(0)
}
guard pages.count == 5 else { exit(2) }
click(pages[1], x: 0.45, y: 0.35)
click(pages[0], x: 0.47, y: 0.90)
click(pages[2], x: 0.94, y: 0.92)
print("Desktop thumbnail, title and row whitespace verified.")

scrollTo(pages[3], down: true)
click(pages[3], x: 0.45, y: 0.42)
print("Desktop scrolling followed by selecting a later page verified.")

scrollTo(pages[0], down: false)
clickElement("sidebar-section-" + pages[0])
Thread.sleep(forTimeInterval: 0.3)
if let hidden = find("slide-thumbnail-" + pages[1]), boundsOf(hidden) != nil {
    fail("Collapsed section still exposes its second page.")
}
scrollTo(pages[4], down: true)
click(pages[4], x: 0.44, y: 0.4)
print("Desktop selection after collapsing the first section verified.")

clickElement("sidebar-search")
let pasteboard = NSPasteboard.general
pasteboard.clearContents()
pasteboard.setString("KS-SEARCH-PAGE-3", forType: .string)
key(0, flags: .maskCommand)
key(9, flags: .maskCommand)
click(pages[2], x: 0.45, y: 0.38)
print("Desktop search-filtered selection verified.")
