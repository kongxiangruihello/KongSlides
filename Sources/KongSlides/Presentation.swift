import AppKit
import SwiftUI

final class PresentationController: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var deck = Deck()
    @Published private(set) var index = 0
    @Published private(set) var started = Date()

    private var projection: NSWindow?
    private var console: NSWindow?
    private var keyboardMonitor: Any?

    func start(deck: Deck, at index: Int) {
        if projection != nil { stop() }
        self.deck = deck
        self.index = index
        started = Date()

        guard let primary = NSApp.keyWindow?.screen ?? NSScreen.main else { return }
        let external = NSScreen.screens.first { $0 != primary }
        let target = external ?? primary

        let projection = ProjectionWindow(contentRect: target.frame, styleMask: [.borderless],
                                          backing: .buffered, defer: false, screen: target)
        projection.contentViewController = NSHostingController(rootView: ProjectionView(session: self))
        projection.isReleasedWhenClosed = false
        projection.backgroundColor = .black
        projection.level = .floating
        projection.delegate = self
        projection.setFrame(target.frame, display: true)
        self.projection = projection
        projection.makeKeyAndOrderFront(nil)

        if external != nil {
            let area = primary.visibleFrame
            let rect = area.insetBy(dx: min(36, area.width * 0.03), dy: min(36, area.height * 0.03))
            let console = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .resizable],
                                   backing: .buffered, defer: false, screen: primary)
            console.contentViewController = NSHostingController(rootView: PresenterView(session: self))
            console.isReleasedWhenClosed = false
            console.title = "KongSlides · 演讲者视图"
            console.delegate = self
            console.setFrame(rect, display: true)
            self.console = console
            console.makeKeyAndOrderFront(nil)
        }

        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = event.window,
                  window === self.projection || window === self.console else { return event }
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
            switch event.keyCode {
            case 53: self.stop()
            case 123, 126, 116: self.step(-1)
            case 124, 125, 121, 49: self.step(1)
            case 115: self.go(to: 0)
            case 119: self.go(to: self.deck.slides.count - 1)
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

    func stop() {
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
        keyboardMonitor = nil
        NotificationCenter.default.removeObserver(self)
        let windows = [projection, console].compactMap { $0 }
        projection = nil
        console = nil
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
        guard let projection else { return }
        if let screen = projection.screen, NSScreen.screens.contains(screen),
           console == nil || screen != console?.screen {
            projection.setFrame(screen.frame, display: true)
        } else {
            stop()
        }
    }
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
