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

struct ChapterRehearsal: Identifiable {
    let id: UUID
    let title: String
    let plannedMinutes: Int?
    var seconds = 0.0
}

final class PresentationController: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var deck = Deck()
    @Published private(set) var index = 0
    @Published private(set) var regularReturnIndex: Int?
    @Published private(set) var started = Date()
    @Published private(set) var dualScreen = false
    @Published var showSingleScreenControls = true
    @Published var blackScreen = false
    @Published var whiteScreen = false
    @Published var noteIndex = 0
    @Published var discussionEnd: Date?
    @Published var drawingEnabled = false
    @Published var ink: [[CGPoint]] = []

    private var projection: NSWindow?
    private var console: NSWindow?
    private var keyboardMonitor: Any?
    private var preferredProjection: UInt32?
    private var preferredConsole: UInt32?
    private var active = false
    private var rehearsalCompletion: (([ChapterRehearsal]) -> Void)?
    private var rehearsalPages: [Int] = []
    private var rehearsal: [ChapterRehearsal] = []
    private var chapterStartedAt = 0.0
    private var customPositions: [Int]?
    private var reviewCompletion: ((ClassroomReview) -> Void)?
    private var visited: [Int] = []
    private var showStartIndex = 0

    var notes: [String] {
        let text = deck.slides[index].speakerNotes
        return text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    func stepNote(_ change: Int) { noteIndex = min(max(0, notes.count - 1), max(0, noteIndex + change)) }
    func toggleBlack() { blackScreen.toggle(); if blackScreen { whiteScreen = false } }
    func toggleWhite() { whiteScreen.toggle(); if whiteScreen { blackScreen = false } }
    var projectionBlanked: Bool { blackScreen || whiteScreen }

    @discardableResult
    func start(deck: Deck, at index: Int, show: ClassroomShow? = nil,
               onReview: ((ClassroomReview) -> Void)? = nil,
               onRehearsalFinished: (([ChapterRehearsal]) -> Void)? = nil) -> Bool {
        let route = show.map { $0.positions(in: deck) }
        let first = route.flatMap(\.first) ?? (show == nil ? deck.firstPresentationIndex(at: index) : nil)
        guard let first else { return false }
        stop()
        self.deck = deck
        self.index = first
        rehearsalCompletion = onRehearsalFinished
        reviewCompletion = onReview
        customPositions = route
        visited = [first]
        showStartIndex = first
        if onRehearsalFinished != nil || onReview != nil {
            for (position, page) in deck.slides.enumerated() {
                if position == 0 || deck.slides[position - 1].section != page.section {
                    rehearsal.append(.init(id: page.id, title: page.section.isEmpty ? "未命名章节" : page.section,
                                           plannedMinutes: page.plannedChapterMinutes))
                }
                rehearsalPages.append(rehearsal.count - 1)
            }
            chapterStartedAt = ProcessInfo.processInfo.systemUptime
        }
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
            case 115: self.goToBoundary(last: false)
            case 119: self.goToBoundary(last: true)
            case 15: self.returnToRegularSlide()
            case 11: self.toggleBlack()
            case 13: self.toggleWhite()
            case 33: if self.dualScreen, window === self.console { self.stepNote(-1) }
            case 30: if self.dualScreen, window === self.console { self.stepNote(1) }
            case 35: self.drawingEnabled.toggle()
            case 8: if !self.dualScreen { self.showSingleScreenControls.toggle() }
            default: return event
            }
            return nil
        }
        NotificationCenter.default.addObserver(self, selector: #selector(displaysChanged(_:)),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        return true
    }

    var bookmarkedIndices: [Int] { deck.slides.indices.filter { deck.slides[$0].bookmarked == true } }

    func visitBookmark(at position: Int) {
        guard bookmarkedIndices.contains(position), index != position else { return }
        let previous = regularReturnIndex ?? index
        go(to: position)
        regularReturnIndex = previous
    }

    var backupIndices: [Int] { deck.slides.indices.filter { deck.slides[$0].isBackup } }

    func sequentialIndex(_ step: Int) -> Int? {
        let current = regularReturnIndex ?? index
        if let customPositions {
            guard let position = customPositions.firstIndex(of: current),
                  customPositions.indices.contains(position + step) else { return nil }
            return customPositions[position + step]
        }
        return deck.presentationIndex(after: current, step: step)
    }

    func step(_ delta: Int) {
        if let next = sequentialIndex(delta) { go(to: next) }
    }

    func go(to position: Int) {
        guard deck.slides.indices.contains(position) else { return }
        if customPositions.map({ !$0.contains(position) }) ?? deck.slides[position].isBackup {
            if regularReturnIndex == nil { regularReturnIndex = index }
        } else {
            regularReturnIndex = nil
        }
        if index != position {
            recordRehearsalElapsed()
            ink.removeAll()
            noteIndex = 0
            if !visited.contains(position) { visited.append(position) }
        }
        index = position
    }

    func returnToRegularSlide() {
        if let regularReturnIndex { go(to: regularReturnIndex) }
    }

    private func goToBoundary(last: Bool) {
        if let customPositions {
            if let target = last ? customPositions.last : customPositions.first { go(to: target) }
            return
        }
        let end = last ? deck.slides.count - 1 : 0
        if let target = deck.firstPresentationIndex(at: end) { go(to: target) }
    }

    func swapScreens() {
        guard dualScreen, let projectionScreen = projection?.screen?.displayID,
              let consoleScreen = console?.screen?.displayID, projectionScreen != consoleScreen else { return }
        preferredProjection = consoleScreen
        preferredConsole = projectionScreen
        configureDisplays()
    }

    private func recordRehearsalElapsed() {
        guard rehearsalPages.indices.contains(index) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        rehearsal[rehearsalPages[index]].seconds += max(0, now - chapterStartedAt)
        chapterStartedAt = now
    }

    func stop() {
        recordRehearsalElapsed()
        let completion = rehearsalCompletion
        let results = rehearsal
        let onReview = reviewCompletion
        let route = customPositions ?? deck.slides.indices.filter { $0 >= showStartIndex && !deck.slides[$0].isBackup }
        let summary = active && onReview != nil ? ClassroomReview(
            date: started, lastPage: deck.slides[index].id,
            visited: visited.map { deck.slides[$0].id },
            skipped: route.filter { !visited.contains($0) }.map { deck.slides[$0].id },
            chapters: results.map { .init(id: $0.id, title: $0.title, plannedMinutes: $0.plannedMinutes, seconds: $0.seconds) }
        ) : nil
        rehearsalCompletion = nil
        reviewCompletion = nil
        customPositions = nil
        visited = []
        rehearsalPages.removeAll()
        rehearsal.removeAll()
        active = false
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
        keyboardMonitor = nil
        NotificationCenter.default.removeObserver(self)
        let windows = [projection, console].compactMap { $0 }
        projection = nil
        console = nil
        dualScreen = false
        regularReturnIndex = nil
        blackScreen = false
        whiteScreen = false
        discussionEnd = nil
        noteIndex = 0
        drawingEnabled = false
        ink.removeAll()
        for window in windows {
            window.delegate = nil
            window.orderOut(nil)
            window.close()
        }
        completion?(results)
        if let summary { onReview?(summary) }
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
            session.whiteScreen ? Color.white : Color.black
            if !session.projectionBlanked {
                SlideSurface(slide: session.deck.slides[session.index], images: session.deck.images, canvas: session.deck.pageCanvas)
                    .overlay { PresentationInk(session: session, interactive: !session.dualScreen) }
            }
        }
        .ignoresSafeArea()
        .overlay(alignment: .bottom) {
            if !session.dualScreen && session.showSingleScreenControls && !session.projectionBlanked {
                HStack(spacing: 14) {
                    Button("上一页") { session.step(-1) }.disabled(session.sequentialIndex(-1) == nil)
                    Text("\(session.index + 1) / \(session.deck.slides.count)").monospacedDigit()
                    Button("下一页") { session.step(1) }.disabled(session.sequentialIndex(1) == nil)
                    BackupPageMenu(session: session)
                    ProjectionTools(session: session)
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
    @State private var showSearch = false
    @State private var discussionMinutes = 5

    private var slide: Slide { session.deck.slides[session.index] }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("第 \(session.index + 1) / \(session.deck.slides.count) 页")
                    .font(.headline).monospacedDigit()
                Text(slide.section).foregroundStyle(.secondary)
                if slide.isBackup { Text("备用页").foregroundStyle(.secondary) }
                Spacer()
                TimelineView(.periodic(from: session.started, by: 1)) { timeline in
                    let elapsed = max(0, Int(timeline.date.timeIntervalSince(session.started)))
                    Text(String(format: "%02d:%02d:%02d", elapsed / 3600, (elapsed / 60) % 60, elapsed % 60))
                        .monospacedDigit().font(.title2)
                }
                Menu("讨论计时") {
                    Picker("时长", selection: $discussionMinutes) {
                        ForEach([1, 2, 3, 5, 10, 15, 20, 30], id: \.self) { minutes in
                            Text("\(minutes) 分钟").tag(minutes)
                        }
                    }
                    Button("开始 \(discussionMinutes) 分钟") {
                        session.discussionEnd = Date().addingTimeInterval(Double(discussionMinutes * 60))
                    }
                    Button("停止计时") { session.discussionEnd = nil }.disabled(session.discussionEnd == nil)
                }
                if let end = session.discussionEnd {
                    TimelineView(.periodic(from: Date(), by: 1)) { time in
                        let seconds = max(0, Int(ceil(end.timeIntervalSince(time.date))))
                        Text(seconds == 0 ? "讨论结束" : String(format: "%02d:%02d", seconds / 60, seconds % 60))
                            .monospacedDigit()
                    }
                }
                TextField("页码", text: $jump).frame(width: 56).onSubmit(go)
                Button("跳页", action: go)
                Button("搜索跳页…") { showSearch = true }
                    .popover(isPresented: $showSearch) { PresenterSearchView(session: session) }
                ProjectionTools(session: session)
                Button("交换屏幕", action: session.swapScreens)
                Button("结束放映", action: session.stop)
            }
            Divider()
            GeometryReader { geometry in
                HStack(alignment: .top, spacing: 16) {
                    previewColumn.frame(width: min(340, max(190, geometry.size.width * 0.34)))
                    Divider()
                    speakerColumn.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 710, minHeight: 490)
    }

    private var previewColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("当前投影 · 第 \(session.index + 1) 页").font(.headline)
            SlideSurface(slide: slide, images: session.deck.images, canvas: session.deck.pageCanvas)
                .overlay { PresentationInk(session: session, interactive: true) }
                .frame(maxHeight: 170)
            HStack {
                Button("上一页") { session.step(-1) }.disabled(session.sequentialIndex(-1) == nil)
                Button("下一页") { session.step(1) }.disabled(session.sequentialIndex(1) == nil)
                Spacer(minLength: 5)
                BackupPageMenu(session: session)
            }
            Text("下一页").font(.headline)
            if let next = session.sequentialIndex(1) {
                SlideSurface(slide: session.deck.slides[next], images: session.deck.images, canvas: session.deck.pageCanvas)
                    .frame(maxHeight: 150)
            } else {
                Text("已到最后一页").foregroundStyle(.secondary)
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private var speakerColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("逐字讲稿").font(.headline)
                Spacer()
                if !session.notes.isEmpty { Text("\(session.noteIndex + 1)/\(session.notes.count) 段").foregroundStyle(.secondary) }
                Button("上一段 [") { session.stepNote(-1) }.disabled(session.noteIndex == 0)
                Button("下一段 ]") { session.stepNote(1) }.disabled(session.noteIndex + 1 >= session.notes.count)
            }
            ScrollViewReader { scroll in
                ScrollView {
                    if let cue = slide.teachingCue {
                        Text(cue.rawValue).font(.headline).foregroundStyle(Color.accentColor)
                    }
                    if session.notes.isEmpty { Text("本页暂无讲稿").foregroundStyle(.secondary) }
                    ForEach(session.notes.indices, id: \.self) { index in
                        let current = index == session.noteIndex
                        HStack(alignment: .top, spacing: 9) {
                            Rectangle().fill(current ? Color.accentColor : Color.clear).frame(width: 4)
                            Text(session.notes[index]).font(.system(size: 21, weight: current ? .semibold : .regular))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 8)
                        }
                        .padding(.horizontal, 6)
                        .background(current ? Color.accentColor.opacity(0.17) : .clear, in: .rect(cornerRadius: 5))
                        .id(index)
                    }
                }
                .onChange(of: session.noteIndex) { scroll.scrollTo(session.noteIndex, anchor: .center) }
                .id(slide.id)
            }
        }
    }

    private func go() {
        guard let number = SlidePageNumber.parse(jump, pageCount: session.deck.slides.count) else { return }
        session.go(to: number - 1)
        jump = ""
    }
}

private struct BackupPageMenu: View {
    @ObservedObject var session: PresentationController

    var body: some View {
        if !session.bookmarkedIndices.isEmpty {
            Menu("课堂书签") {
                ForEach(session.bookmarkedIndices, id: \.self) { index in
                    Button("第 \(index + 1) 页 · \(session.deck.slides[index].title)") { session.visitBookmark(at: index) }
                }
            }
        }
        if !session.backupIndices.isEmpty {
            Menu("备用页") {
                ForEach(session.backupIndices, id: \.self) { index in
                    Button("第 \(index + 1) 页 · \(session.deck.slides[index].title)") { session.go(to: index) }
                }
            }
        }
        if session.regularReturnIndex != nil {
            Button("返回讲授页", action: session.returnToRegularSlide).help("按 R 返回临时跳转前的位置")
        }
    }
}

private struct ProjectionTools: View {
    @ObservedObject var session: PresentationController

    var body: some View {
        Menu("放映工具") {
            Button(session.blackScreen ? "恢复投影（B）" : "黑屏（B）", action: session.toggleBlack)
            Button(session.whiteScreen ? "恢复投影（W）" : "白屏（W）", action: session.toggleWhite)
            Button(session.drawingEnabled ? "停用临时画笔（P）" : "启用临时画笔（P）") {
                session.drawingEnabled.toggle()
            }
            Button("清除本页笔迹") { session.ink.removeAll() }.disabled(session.ink.isEmpty)
        }
    }
}

private struct PresentationInk: View {
    @ObservedObject var session: PresentationController
    let interactive: Bool
    @GestureState private var drawing = false
    @State private var lastStroke: Int?

    var body: some View {
        Canvas { graphics, size in
            for stroke in session.ink {
                var line = Path()
                let points = stroke.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
                line.addLines(points)
                graphics.stroke(line, with: .color(.red), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
        }
        .clipped()
        .overlay {
            if interactive && session.drawingEnabled && !session.projectionBlanked {
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0)
                            .updating($drawing) { _, active, _ in active = true }
                            .onChanged { value in
                                let w = max(1, geometry.size.width)
                                let h = max(1, geometry.size.height)
                                let point = CGPoint(x: min(1, max(0, value.location.x / w)),
                                                    y: min(1, max(0, value.location.y / h)))
                                if let lastStroke, session.ink.indices.contains(lastStroke) {
                                    session.ink[lastStroke].append(point)
                                } else {
                                    session.ink.append([point])
                                    lastStroke = session.ink.count - 1
                                }
                            }
                            .onEnded { _ in lastStroke = nil })
                }
            }
        }
        .onChange(of: drawing) { if !drawing { lastStroke = nil } }
        .allowsHitTesting(interactive && session.drawingEnabled && !session.projectionBlanked)
    }
}

private struct PresenterSearchView: View {
    @ObservedObject var session: PresentationController
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var active: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("仅教师可见", systemImage: "lock").font(.headline)
            Text("当前投影第 \(session.index + 1) 页")
                .font(.caption).foregroundStyle(.secondary)
            TextField("章节名称、标题或关键词", text: $query)
            HStack {
                List(filtered, id: \.self, selection: $active) { index in
                    let page = session.deck.slides[index]
                    Text("\(index + 1)  \(page.section)  \(page.title)").tag(index)
                }
                if let active {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("待切换第 \(active + 1) 页").font(.headline)
                        SlideSurface(slide: session.deck.slides[active], images: session.deck.images, canvas: session.deck.pageCanvas)
                    }
                }
            }
            HStack {
                Spacer()
                Button(active.map { "切到第 \($0 + 1) 页" } ?? "选中一页后切换") {
                    if let active { session.go(to: active); dismiss() }
                }.buttonStyle(.borderedProminent).disabled(active == nil)
            }
        }.padding(15).frame(width: 590, height: 330)
         .onChange(of: query) { active = nil }
    }

    private var filtered: [Int] {
        session.deck.slides.indices.filter { query.isEmpty || SlideSearchHit.first(on: session.deck.slides[$0], query: query) != nil }
    }
}
