import AppKit
import SwiftUI

struct PresentationDisplays: Equatable {
    let projection: UInt32
    let console: UInt32?

    static func resolve(_ available: [UInt32], preferProjection: UInt32?, preferConsole: UInt32?) -> Self? {
        guard let first = available.first else { return nil }
        if available.count == 1 { return Self(projection: first, console: nil) }
        let teacher = available.first { $0 == preferConsole }
            ?? available.first { $0 != preferProjection } ?? first
        let audience = available.first { $0 != teacher && $0 == preferProjection }
            ?? available.first { $0 != teacher } ?? first
        return Self(projection: audience, console: teacher)
    }
}

final class PresentationController: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var deck = Deck()
    @Published private(set) var index = 0
    @Published private(set) var started = Date()
    @Published private(set) var dualScreen = false
    @Published var showSingleScreenControls = true

    private var projection: NSWindow?
    private var console: NSWindow?
    private var keyboardMonitor: Any?
    private var preferredProjection: UInt32?
    private var preferredConsole: UInt32?
    private var active = false

    func start(deck: Deck, at index: Int) {
        stop()
        self.deck = deck
        go(to: index)
        started = Date()
        active = true
        showSingleScreenControls = true
        preferredConsole = (NSApp.keyWindow?.screen ?? NSScreen.main)?.displayID
        preferredProjection = NSScreen.screens.first { $0.displayID != preferredConsole }?.displayID
        configureDisplays()

        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = event.window,
                  window === self.projection || window === self.console else { return event }
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
            if event.keyCode == 53 { self.stop(); return nil }
            if window.firstResponder is NSTextView { return event }
            switch event.keyCode {
            case 123, 126, 116: self.step(-1)
            case 124, 125, 121, 49: self.step(1)
            case 115: self.go(to: 0)
            case 119: self.go(to: self.deck.slides.count - 1)
            case 8: if !self.dualScreen { self.showSingleScreenControls.toggle() }
            default: return event
            }
            return nil
        }
        NotificationCenter.default.addObserver(self, selector: #selector(displaysChanged(_:)),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    func step(_ delta: Int) { go(to: index + delta) }

    func go(to position: Int) {
        index = min(max(position, 0), deck.slides.count - 1)
    }

    func swapScreens() {
        guard dualScreen, let projectionScreen = projection?.screen?.displayID,
              let consoleScreen = console?.screen?.displayID, projectionScreen != consoleScreen else { return }
        preferredProjection = consoleScreen
        preferredConsole = projectionScreen
        configureDisplays()
    }

    func stop() {
        active = false
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
        keyboardMonitor = nil
        NotificationCenter.default.removeObserver(self)
        let windows = [projection, console].compactMap { $0 }
        projection = nil
        console = nil
        dualScreen = false
        for window in windows {
            window.delegate = nil
            window.orderOut(nil)
            window.close()
        }
    }

    func windowWillClose(_ notification: Notification) {
        if let closing = notification.object as? NSWindow {
            if projection === closing { projection = nil }
            if console === closing { console = nil }
        }
        stop()
    }

    @objc private func displaysChanged(_ notification: Notification) {
        if active { configureDisplays() }
    }

    private func configureDisplays() {
        // Hide the private window before rearranging either display.
        console?.orderOut(nil)
        let screens = NSScreen.screens
        guard let layout = PresentationDisplays.resolve(screens.compactMap(\.displayID),
                                                         preferProjection: preferredProjection,
                                                         preferConsole: preferredConsole),
              let target = screens.first(where: { $0.displayID == layout.projection }) else {
            projection?.orderOut(nil)
            return
        }
        let teacher = layout.console.flatMap { id in screens.first { $0.displayID == id } }
        dualScreen = teacher != nil
        showSingleScreenControls = teacher == nil

        let projection = self.projection ?? makeProjection(on: target)
        self.projection = projection
        projection.setFrame(target.frame, display: true)
        projection.makeKeyAndOrderFront(nil)
        if let teacher {
            let area = teacher.visibleFrame
            let frame = area.insetBy(dx: min(36, area.width * 0.03), dy: min(36, area.height * 0.03))
            let console = self.console ?? makeConsole(frame: frame, on: teacher)
            self.console = console
            console.setFrame(frame, display: true)
            guard console.screen?.displayID == teacher.displayID,
                  console.screen?.displayID != projection.screen?.displayID else {
                dualScreen = false
                showSingleScreenControls = true
                return
            }
            console.makeKeyAndOrderFront(nil)
        }
    }

    private func makeProjection(on screen: NSScreen) -> NSWindow {
        let window = ProjectionWindow(contentRect: screen.frame, styleMask: [.borderless],
                                      backing: .buffered, defer: false, screen: screen)
        window.contentViewController = NSHostingController(rootView: ProjectionView(session: self))
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.level = .floating
        window.delegate = self
        return window
    }

    private func makeConsole(frame: CGRect, on screen: NSScreen) -> NSWindow {
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false, screen: screen)
        window.contentViewController = NSHostingController(rootView: PresenterView(session: self))
        window.isReleasedWhenClosed = false
        window.title = "KongSlides · 演讲者视图"
        window.delegate = self
        return window
    }
}

private extension NSScreen {
    var displayID: UInt32? { (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value }
}

private final class ProjectionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private struct ProjectionView: View {
    @ObservedObject var session: PresentationController

    var body: some View {
        ZStack {
            Color.black
            SlideSurface(slide: session.deck.slides[session.index], images: session.deck.images)
        }
        .ignoresSafeArea()
        .overlay(alignment: .bottom) {
            if !session.dualScreen && session.showSingleScreenControls {
                HStack(spacing: 14) {
                    Button("上一页") { session.step(-1) }.disabled(session.index == 0)
                    Text("\(session.index + 1) / \(session.deck.slides.count)").monospacedDigit()
                    Button("下一页") { session.step(1) }.disabled(session.index + 1 == session.deck.slides.count)
                    Button("隐藏控件") { session.showSingleScreenControls = false }.help("按 C 再显示控件")
                    Button("结束放映", action: session.stop)
                }
                .padding(12).background(.regularMaterial, in: .rect(cornerRadius: 12))
                .padding(.bottom, 22)
            }
        }
    }
}

private struct PresenterView: View {
    @ObservedObject var session: PresentationController
    @State private var jump = ""

    private var slide: Slide { session.deck.slides[session.index] }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("第 \(session.index + 1) / \(session.deck.slides.count) 页")
                    .font(.headline).monospacedDigit()
                Text(slide.section).foregroundStyle(.secondary)
                Spacer()
                TimelineView(.periodic(from: session.started, by: 1)) { timeline in
                    let elapsed = max(0, Int(timeline.date.timeIntervalSince(session.started)))
                    Text(String(format: "%02d:%02d:%02d", elapsed / 3600, (elapsed / 60) % 60, elapsed % 60))
                        .monospacedDigit().font(.title2)
                }
                Button("交换屏幕", action: session.swapScreens)
                Button("结束放映", action: session.stop)
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading) {
                    Text("当前页").font(.headline)
                    SlideSurface(slide: slide, images: session.deck.images)
                    HStack {
                        Button("上一页") { session.step(-1) }.disabled(session.index == 0)
                        Button("下一页") { session.step(1) }.disabled(session.index + 1 == session.deck.slides.count)
                        Spacer()
                        TextField("页码", text: $jump).frame(width: 65).onSubmit(go)
                        Button("跳页", action: go)
                    }
                }
                VStack(alignment: .leading) {
                    Text("下一页").font(.headline)
                    if session.index + 1 < session.deck.slides.count {
                        SlideSurface(slide: session.deck.slides[session.index + 1], images: session.deck.images)
                    } else {
                        Text("已到最后一页").foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: 280)
            }
            Divider()
            Text("逐字讲稿").font(.headline)
            ScrollView {
                Text(slide.speakerNotes.isEmpty ? "本页暂无讲稿" : slide.speakerNotes)
                    .font(.system(size: 21))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(slide.id)
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 460)
    }

    private func go() {
        guard let number = Int(jump), (1...session.deck.slides.count).contains(number) else { return }
        session.go(to: number - 1)
        jump = ""
    }
}
