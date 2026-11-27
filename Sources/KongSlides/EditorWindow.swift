import AppKit
import SwiftUI

@MainActor
final class EditorWindow: NSWindowController, NSWindowDelegate, NSMenuDelegate {
    let session = EditorFileSession()

    init() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1280, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.identifier = NSUserInterfaceItemIdentifier("KongSlidesEditor")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: EditorWindowContent(session: session))
        window.contentMinSize = NSSize(width: 1040, height: 660)
        window.setFrameAutosaveName("KongSlidesEditor")
        window.center()
        session.statusChanged = { [weak self] in self?.updateTitle() }
        updateTitle()
    }

    required init?(coder: NSCoder) { nil }

    func showEditor() {
        showWindow(nil)
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
    }

    func open(_ url: URL) {
        showEditor()
        session.open(url)
    }

    private func updateTitle() {
        window?.title = "\(session.name) — KongSlides"
        window?.representedURL = session.fileURL
        window?.isDocumentEdited = session.isEdited
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { session.confirmReplacement() }

    func windowWillClose(_ notification: Notification) { session.resetAfterClose() }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { session.undoManager }

    @objc private func newDeck(_ sender: Any?) {
        showEditor()
        session.newDeck()
    }

    @objc private func chooseFile(_ sender: Any?) {
        showEditor()
        session.chooseFile()
    }

    @objc private func save(_ sender: Any?) { session.save() }
    @objc private func saveAs(_ sender: Any?) { session.save(asCopy: true) }
    @objc private func openRecent(_ item: NSMenuItem) {
        if let url = item.representedObject as? URL { open(url) }
    }

    @objc private func clearRecent(_ sender: Any?) { NSDocumentController.shared.clearRecentDocuments(nil) }
    @objc private func undo(_ sender: Any?) { currentUndoManager.undo() }
    @objc private func redo(_ sender: Any?) { currentUndoManager.redo() }

    private var currentUndoManager: UndoManager {
        (window?.firstResponder as? NSTextView)?.undoManager ?? session.undoManager
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        Task { await SoftwareUpdate.shared.check(manual: true) }
    }

    @objc private func toggleUpdates(_ item: NSMenuItem) {
        let enabled = item.state != .on
        UserDefaults.standard.set(enabled, forKey: SoftwareUpdate.automaticKey)
        item.state = enabled ? .on : .off
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let urls = NSDocumentController.shared.recentDocumentURLs
        if urls.isEmpty {
            let empty = NSMenuItem(title: "没有最近使用的课件", action: nil, keyEquivalent: "")
            menu.addItem(empty)
        }
        for url in urls {
            let item = NSMenuItem(title: url.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.toolTip = url.path
            menu.addItem(item)
        }
        if !urls.isEmpty {
            menu.addItem(.separator())
            let clear = NSMenuItem(title: "清除菜单", action: #selector(clearRecent(_:)), keyEquivalent: "")
            clear.target = self
            menu.addItem(clear)
        }
    }

    func installMenus() {
        let menu = NSMenu()
        func addMenu(_ title: String) -> NSMenu {
            let entry = NSMenuItem()
            let submenu = NSMenu(title: title)
            entry.submenu = submenu
            menu.addItem(entry)
            return submenu
        }

        @discardableResult
        func item(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "",
                  target: AnyObject? = nil, modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = target
            item.keyEquivalentModifierMask = modifiers
            menu.addItem(item)
            return item
        }

        let application = addMenu("KongSlides")
        item(application, "关于 KongSlides", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        item(application, "检查更新…", #selector(checkForUpdates(_:)), target: self)
        let automatic = item(application, "自动检查更新", #selector(toggleUpdates(_:)), target: self)
        automatic.state = (UserDefaults.standard.object(forKey: SoftwareUpdate.automaticKey) as? Bool ?? true) ? .on : .off
        application.addItem(.separator())
        item(application, "隐藏 KongSlides", #selector(NSApplication.hide(_:)), "h")
        application.addItem(.separator())
        item(application, "退出 KongSlides", #selector(NSApplication.terminate(_:)), "q")

        let file = addMenu("文件")
        item(file, "新建课件", #selector(newDeck(_:)), "n", target: self)
        item(file, "打开…", #selector(chooseFile(_:)), "o", target: self)
        let recent = NSMenuItem(title: "最近使用", action: nil, keyEquivalent: "")
        recent.submenu = NSMenu(title: "最近使用")
        recent.submenu?.delegate = self
        file.addItem(recent)
        file.addItem(.separator())
        item(file, "关闭窗口", #selector(NSWindow.performClose(_:)), "w")
        item(file, "保存", #selector(save(_:)), "s", target: self)
        item(file, "另存为…", #selector(saveAs(_:)), "s", target: self, modifiers: [.command, .shift])

        let edit = addMenu("编辑")
        item(edit, "撤销", #selector(undo(_:)), "z", target: self)
        item(edit, "重做", #selector(redo(_:)), "z", target: self, modifiers: [.command, .shift])
        edit.addItem(.separator())
        item(edit, "剪切", #selector(NSText.cut(_:)), "x")
        item(edit, "复制", #selector(NSText.copy(_:)), "c")
        item(edit, "粘贴", #selector(NSText.paste(_:)), "v")
        item(edit, "全选", #selector(NSText.selectAll(_:)), "a")

        let window = addMenu("窗口")
        item(window, "最小化", #selector(NSWindow.performMiniaturize(_:)), "m")
        item(window, "缩放", #selector(NSWindow.performZoom(_:)))
        NSApp.windowsMenu = window
        NSApp.mainMenu = menu
    }
}

private struct EditorWindowContent: View {
    let session: EditorFileSession

    var body: some View {
        EditorView(document: Binding(get: { session.document }, set: { session.edit($0) }), session: session)
            .id(session.identity)
            .frame(minWidth: 1040, minHeight: 660)
            .tint(Color(nsColor: Palette.color(Palette.indigo)))
            .environment(\.undoManager, session.undoManager)
    }
}
