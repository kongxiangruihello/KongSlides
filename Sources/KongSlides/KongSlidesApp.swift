import AppKit
import ImageIO
import Observation
import SwiftUI
import UniformTypeIdentifiers

@main
struct KongSlidesApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let lifecycle = AppLifecycle()
        application.delegate = lifecycle
        application.setActivationPolicy(.regular)
        withExtendedLifetime(lifecycle) { application.run() }
    }
}

struct SlideSurface: View {
    let slide: Slide
    let images: [UUID: Data]
    var omittedObject: UUID? = nil
    var hiddenObjects: Set<UUID> = []
    var canvas: SlideCanvas = .widescreen
    var imageCache: SlideImageCache? = nil
    var thumbnail = false
    var didDraw: ((Double, Double) -> Void)? = nil

    var body: some View {
        Canvas(rendersAsynchronously: thumbnail) { graphics, size in
            guard size.width > 0, size.height > 0 else { return }
            var imageTime = 0.0
            graphics.withCGContext { context in
                var visible = slide
                visible.objects.removeAll { $0.id == omittedObject || hiddenObjects.contains($0.id) }
                context.translateBy(x: 0, y: size.height)
                context.scaleBy(x: size.width / canvas.width, y: -size.height / canvas.height)
                SlideDrawing.draw(visible, images: images, in: context, canvas: canvas,
                                  cachedPicture: imageCache.map { cache in
                    { data, id in
                        let start = OpenTiming.now
                        let image = cache.picture(data, id: id, thumbnail: thumbnail)
                        imageTime += OpenTiming.now - start
                        return image
                    }
                })
            }
            if let didDraw { didDraw(OpenTiming.now, imageTime) }
        }
        .aspectRatio(canvas.width / canvas.height, contentMode: .fit)
        .accessibilityLabel(slide.title)
    }
}

struct EditorView: View {
    @Binding var document: SlidesDocument
    let session: EditorFileSession
    let documentIdentity: UUID
    @State private var slideID: UUID?
    @State private var imageCache = SlideImageCache()
    @State private var showOpenTiming = false
    @State private var classroomSheet: ClassroomToolSheet?
    @State private var exportReceipt: ExportReceipt?
    @State private var detailedReceipt: ExportReceipt?
    @State private var exportBusy = false
    @State private var slideFilter = ClassroomSlideFilter.all
    @State private var workspaceLayout = ClassroomWorkspaceLayout.full
    @State private var styleBrush: SlideTextRun?
    @State private var zoomPercent: Double?
    @State private var locatedObject: UUID?
    @State private var locateTask: Task<Void, Never>?
    @State private var sidebarVisibleChapter: UUID?
    @State private var hiddenObjects: Set<UUID> = []
    @State private var renameTarget: SlideObject?
    @State private var objectName = ""
    @AppStorage("snapCanvasObjects") private var snapEnabled = true
    @State private var canvasSnap: CanvasSnap?
    @State private var draggingPage: UUID?
    @State private var pageDropTarget: UUID?
    @State private var pageDropAfter = false
    @State private var edgeScrollAnchor: UUID?
    @State private var edgeScroll: Task<Void, Never>?
    @State private var selectedPageIDs: Set<UUID> = []
    @State private var pageSelectionAnchor: UUID?
    @State private var pageToReveal: UUID?
    @State private var visitHistory = SlideVisitHistory()
    @State private var pageJumpSheet = false
    @State private var overviewSheet = false
    @State private var citationSheet = false
    @State private var rehearsalSheet = false
    @State private var rehearsedChapters: [ChapterRehearsal] = []
    @State private var pendingJump: Int?
    @State private var collapsedSections: Set<UUID> = []
    @State private var pageCommands = false
    @State private var pendingDeletion: Set<UUID> = []
    @State private var notesFocus = false
    @State private var teachingSheet: TeachingSheet?
    @State private var canvasSheet = false
    @State private var fontReplacementSheet = false
    @State private var formatText: SlideObject?
    @State private var editTable: SlideObject?
    @State private var recoverySheet = false
    @State private var recoveryID = UUID()
    @State private var recoveryPending: Task<Void, Never>?
    @State private var referencePDF: ReferenceFile?
    @State private var savedSnapshot: DeckSnapshot?
    @ObservedObject private var templateStore = TeachingTemplateStore.shared
    @AppStorage("speakerNotesFontSize") private var notesFontSize = 16.0
    @State private var notesHeight = 108.0
    @GestureState private var notesResize = 0.0
    @State private var objectID: UUID?
    @State private var additionalObjects = Set<UUID>()
    @GestureState private var objectMarquee: CGRect?
    @State private var editingID: UUID?
    @State private var selectedTextRanges: [Range<Int>] = []
    @State private var selectNewText = false
    @State private var linkedError: String?
    @State private var reviewMode: SlideReviewMode?
    @State private var preflightRows: [SlideReviewRow] = []
    @State private var preflightPageCount = 0
    @State private var checkingPreflight = false
    @State private var importing = false
    @State private var importTask: Task<PowerPoint.ImportedDeck, Error>?
    @State private var importProgress = ImportProgress()
    @AppStorage("showSpeakerNotes") private var showNotes = true
    @AppStorage("showLayoutInspector") private var showInspector = true
    @AppStorage("sidebarWidth") private var sidebarWidth = 206.0
    @AppStorage("inspectorWidth") private var inspectorWidth = 230.0
    @State private var sidebarDrag = 0.0
    @State private var inspectorDrag = 0.0
    @State private var search = ""
    @State private var presenter = PresentationController()

    init(document: Binding<SlidesDocument>, session: EditorFileSession, documentIdentity: UUID) {
        _document = document
        self.session = session
        self.documentIdentity = documentIdentity
        let page = session.activePageID
        _slideID = State(initialValue: page)
        _selectedPageIDs = State(initialValue: page.map { [$0] } ?? [])
        _pageSelectionAnchor = State(initialValue: page)
    }

    private var deck: Deck { document.deck }
    private var index: Int { deck.slides.firstIndex { $0.id == slideID } ?? 0 }
    private var slide: Slide { deck.slides[index] }
    private var selectedPages: Set<UUID> { selectedPageIDs.intersection(deck.slides.map(\.id)) }
    private var selectedObjects: Set<UUID> {
        let valid = Set(slide.objects.filter { !$0.isLocked }.map(\.id))
        return additionalObjects.union(objectID.map { [$0] } ?? []).intersection(valid)
    }
    private var selection: Int? { slide.objects.firstIndex { $0.id == objectID } }
    private var formattingObject: SlideObject? {
        guard selectedObjects.count == 1, let selection else { return nil }
        let object = slide.objects[selection]
        return object.kind == .text && !object.isLocked ? object : nil
    }

    var body: some View { editorAlerts }

    private var editorSurface: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            EditorFormattingToolbar(
                object: formattingObject,
                ranges: formattingObject.map { object in
                    selectedTextRanges.filter { $0.upperBound <= object.text.utf16.count }
                } ?? [],
                insertTextBox: insertTextBox,
                update: formatSelectedText,
                editingText: editingID != nil,
                paintReady: styleBrush != nil,
                paint: useStyleBrush
            )
            if importing || session.opening {
                let progress = session.opening ? session.progress : importProgress
                HStack {
                    if let count = progress.total, count > 0 {
                        ProgressView(value: Double(progress.completed), total: Double(count))
                        Text("\(progress.completed) / \(count) 页").monospacedDigit()
                    } else {
                        ProgressView().controlSize(.small)
                        Text("正在打开课件…")
                    }
                    Spacer()
                    Button("取消") {
                        if session.opening { session.cancelOpening() } else { importTask?.cancel() }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
            }
            Divider()
            editorPanels
            Divider()
            editorStatusBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .background(EditorKeyMonitor(handle: handleShortcut, flagsChanged: { event in
            if event.modifierFlags.contains(.option) { canvasSnap = nil }
        }))
        .onAppear {
            if deck.slides.first?.id != slideID { pageToReveal = slideID }
            if deck.importedTitle != nil && deck.slides.contains(where: { $0.importReport != nil }) {
                reviewMode = .imported
            }
            if RecoverySession.shared.shouldOffer() { recoverySheet = true }
        }
        .onDisappear {
            importTask?.cancel()
            recoveryPending?.cancel()
            edgeScroll?.cancel()
            locateTask?.cancel()
            RecoverySession.shared.close(recoveryID)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !importing, urls.count == 1, let url = urls.first,
                  url.isFileURL, ["kongslides", "pptx", "ppt"].contains(url.pathExtension.lowercased()) else { return false }
            session.open(url)
            return true
        }
        .onChange(of: session.pageJumpRequest) { pageJumpSheet = true }
    }

    private var editorNavigation: some View {
        editorSurface
        .sheet(isPresented: $rehearsalSheet) {
            VStack(alignment: .leading, spacing: 10) {
                Text("章节排练记录").font(.headline)
                List(rehearsedChapters) { chapter in
                    HStack {
                        Text(chapter.title)
                        Spacer()
                        let seconds = Int(chapter.seconds)
                        Text("实际 \(seconds / 60) 分 \(seconds % 60) 秒")
                        if let minutes = chapter.plannedMinutes { Text("计划 \(minutes) 分").foregroundStyle(.secondary) }
                    }
                }
                Button("关闭") { rehearsalSheet = false }.keyboardShortcut(.cancelAction)
            }.padding(18).frame(width: 470, height: 320)
        }
        .sheet(isPresented: $citationSheet) {
            let page = slide.id
            SlideCitationView(citation: slide.citation ?? .init()) { updated in
                if let index = deck.slides.firstIndex(where: { $0.id == page }) {
                    document.deck.slides[index].citation = updated == .init() ? nil : updated
                }
            }
        }
        .sheet(isPresented: $showOpenTiming) {
            VStack(alignment: .leading, spacing: 12) {
                Text("课件打开耗时").font(.headline)
                Text(session.openTiming?.report ?? "尚无打开记录。").monospacedDigit().textSelection(.enabled)
                Button("关闭") { showOpenTiming = false }.keyboardShortcut(.cancelAction)
            }
            .padding(18).frame(minWidth: 440)
        }
        .sheet(isPresented: $overviewSheet) {
            SlideOverview(deck: deck, current: slide.id, imageCache: imageCache, open: { id in
                search = ""
                selectPages([id])
            }, reorder: reorderOverviewPage, setBackup: setBackup)
        }
        .sheet(isPresented: $pageJumpSheet, onDismiss: applyPageJump) {
            PageJumpView(currentPage: index + 1, pageCount: deck.slides.count) { pendingJump = $0 }
        }
        .onChange(of: session.homeAction) { _, request in
            guard session.identity == documentIdentity, let request else { return }
            session.homeAction = nil
            switch request.action {
            case .preflight: runPreflight()
            case .rehearsal: startRehearsal()
            case .classroomPackage: exportClassroomPackage()
            }
        }
        .sheet(isPresented: $notesFocus, onDismiss: { selectPages([slide.id]) }) {
            NotesFocusView(document: $document, slideID: $slideID, fontSize: $notesFontSize)
        }
        .onChange(of: deck) { _, latest in
            recoveryPending?.cancel()
            let id = recoveryID
            let name = session.name
            recoveryPending = Task { @MainActor in
                do {
                    try await Task.sleep(for: .seconds(1))
                    RecoverySession.shared.write(RecoverySnapshot(savedAt: Date(), name: name, deck: latest), id: id)
                } catch {}
            }
        }
    }

    private var editorDocuments: some View {
        editorNavigation
        .sheet(isPresented: $recoverySheet) {
            RecoveryBrowser { original, name in
                var copy = original
                copy.importedTitle = name + "（恢复）"
                return session.replace(with: copy, markEdited: true)
            }
        }
        .sheet(isPresented: $canvasSheet) {
            CanvasSizeView(deck: deck, slideID: slide.id) { size in document.deck = deck.fitted(to: size) }
        }
        .sheet(isPresented: $fontReplacementSheet) {
            FontReplacementView(names: SlideFonts.requested(in: deck)) { source, replacement in
                var changed = deck
                SlideFonts.replace(source, with: replacement, in: &changed)
                if changed != deck { document.deck = changed }
                if reviewMode == .preflight { runPreflight() }
            }
        }
        .sheet(item: $formatText) { object in
            TextRunFormatView(object: object) { runs in
                if let index = slide.objects.firstIndex(where: { $0.id == object.id }) {
                    document.deck.slides[self.index].objects[index].textRuns = runs.isEmpty ? nil : runs
                }
            }
        }
        .sheet(item: $editTable) { object in
            if let table = object.table {
                SlideTableEditor(table: table) { updated in
                    objectBinding(object.id, \.table, fallback: nil).wrappedValue = updated
                }
            }
        }
    }

    private var editorSheets: some View {
        editorDocuments
        .sheet(item: $savedSnapshot) { snapshot in
            DeckSnapshotView(snapshot: snapshot, current: deck) { selection, notesOnly in
                do {
                    var restored = deck
                    if notesOnly, let selection {
                        for index in restored.slides.indices where selection.contains(restored.slides[index].id) {
                            if let old = snapshot.deck.slides.first(where: { $0.id == restored.slides[index].id }) {
                                restored.slides[index].speakerNotes = old.speakerNotes
                            }
                        }
                    } else {
                        restored = try selection.map { try snapshot.restoring($0, into: deck) } ?? snapshot.deck
                    }
                    let current = restored.slides.first(where: { $0.id == slide.id }) ?? restored.slides.first
                    document.deck = restored
                    search = ""
                    if let current { selectPages([current.id]) }
                } catch { linkedError = error.localizedDescription }
            }
        }
        .sheet(item: $referencePDF) { reference in
            ReferencePDFView(url: reference.url, deck: deck, selectedSlide: reference.selectedSlide, replace: replaceWithReference)
        }
        .sheet(item: $teachingSheet) { sheet in
            switch sheet {
            case .outline:
                TeachingOutlineView(templates: TeachingTemplate.builtIns + templateStore.items.filter(\.canGenerate)) {
                    insert($0, at: index + 1, asObject: false)
                }
            case .templates:
                TeachingTemplateView(library: templateStore) { item in
                    var page = item.slide
                    page.section = slide.section
                    insert(SlideClipboard(slides: [page], images: item.images, canvas: item.canvas), at: index + 1, asObject: false)
                }
            }
        }
        .sheet(item: $classroomSheet) { classroomTool($0) }
        .sheet(item: $detailedReceipt) { receipt in
            ExportReceiptView(receipt: receipt) { page in
                if deck.slides.contains(where: { $0.id == page }) { selectPages([page]) }
            }
        }
        .onChange(of: session.exportReceipt?.id) {
            if let receipt = session.exportReceipt {
                session.exportReceipt = nil
                exportReceipt = receipt
            }
        }
    }

    private var editorAlerts: some View {
        editorSheets
        .alert("重命名对象", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("名称", text: $objectName)
            Button("取消", role: .cancel) { renameTarget = nil }
            Button("保存") {
                if let target = renameTarget {
                    let value = objectName.trimmingCharacters(in: .whitespacesAndNewlines)
                    objectBinding(target.id, \.objectName, fallback: nil).wrappedValue = value.isEmpty ? nil : value
                }
                renameTarget = nil
            }
        }
        .alert("删除 \(pendingDeletion.count) 页幻灯片？", isPresented: Binding(
            get: { !pendingDeletion.isEmpty }, set: { if !$0 { pendingDeletion = [] } }
        )) {
            Button("删除", role: .destructive) {
                deleteSlides(pendingDeletion)
                pendingDeletion = []
            }
            Button("取消", role: .cancel) { pendingDeletion = [] }
        } message: { Text("所选页面及其讲稿会一起移除。") }
        .onChange(of: slide.id) {
            session.rememberPage(slide.id, for: documentIdentity)
            if selection == nil { objectID = nil }
            additionalObjects.removeAll()
            editingID = nil
            canvasSnap = nil
            locatedObject = nil
        }
        .onChange(of: objectID) {
            if editingID != objectID {
                editingID = nil
                selectedTextRanges = []
            }
        }
        .alert("操作未完成", isPresented: Binding(
            get: { session.screen == .editor && (linkedError != nil || session.error != nil) },
            set: { if !$0 { linkedError = nil; session.error = nil } }
        )) {
            Button("好", role: .cancel) { linkedError = nil; session.error = nil }
        } message: { Text(linkedError ?? session.error ?? "") }

    }

    private var editorPanels: some View {
        GeometryReader { geometry in
            let widths = EditorPanelWidths(windowWidth: geometry.size.width, preferredLeft: sidebarWidth,
                                          preferredRight: showInspector && workspaceLayout == .full ? inspectorWidth : nil)
            HStack(spacing: 0) {
                if workspaceLayout == .full {
                    sidebar.frame(width: widths.width(.left, translation: sidebarDrag))
                    EditorPanelResizeHandle(title: "拖动调整缩略图栏宽度，双击恢复默认", identifier: "resize-slide-sidebar",
                                            translation: $sidebarDrag, resize: { offset in
                        let width = widths.width(.left, translation: offset)
                        if width != widths.left { sidebarWidth = width }
                    }, reset: { sidebarWidth = 206 })
                    .frame(width: EditorPanelWidths.dividerWidth)
                    .frame(maxHeight: .infinity)
                    .overlay(alignment: .top) {
                        if sidebarDrag != 0 { panelWidthBadge(widths.width(.left, translation: sidebarDrag)) }
                    }
                    .zIndex(1)
                }
                VStack(spacing: 0) {
                    if workspaceLayout != .notes { workspace }
                    if workspaceLayout == .notes || (showNotes && workspaceLayout == .full) {
                        Divider()
                        notes
                    }
                    if workspaceLayout == .full, let reviewMode {
                        Divider()
                        reviewPanel(reviewMode)
                    }
                }
                if showInspector && workspaceLayout == .full {
                    EditorPanelResizeHandle(title: "拖动调整版面属性宽度，双击恢复默认", identifier: "resize-layout-inspector",
                                            translation: $inspectorDrag, resize: { offset in
                        let width = widths.width(.right, translation: offset)
                        if width != widths.right { inspectorWidth = width }
                    }, reset: { inspectorWidth = 230 })
                    .frame(width: EditorPanelWidths.dividerWidth)
                    .frame(maxHeight: .infinity)
                    .overlay(alignment: .top) {
                        if inspectorDrag != 0 { panelWidthBadge(widths.width(.right, translation: inspectorDrag)) }
                    }
                    .zIndex(1)
                    inspector.frame(width: widths.width(.right, translation: inspectorDrag))
                }
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 9) {
            Button { session.showHome() } label: { Image(systemName: "house") }
                .help("返回首页").accessibilityLabel("返回首页")
            HStack(spacing: 8) {
                Image(systemName: "rectangle.on.rectangle").foregroundStyle(Color.accentColor)
                Text("KongSlides").font(.headline)
            }
            Divider().frame(height: 21)
            Menu {
                Button("空白页") { addSlide(Slide()) }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("标题页") { addSlide(.titleSlide("新章节", subtitle: "输入副标题")) }
                Button("原文与解读") { addSlide(.readingSlide()) }
                Divider()
                Button("从提纲生成课件…") { teachingSheet = .outline }
                Button("从教学版式新建…") { teachingSheet = .templates }
                Button("保存当前页为版式…", action: saveCurrentTemplate)
            } label: { Label("新建页", systemImage: "plus.rectangle") }
            .fixedSize()
            Button(action: addImage) { Label("图片", systemImage: "photo") }
            Button {
                let table = SlideTable(columns: [1, 1, 1], rows: [1, 1, 1], cells: (0..<9).map {
                    SlideTable.Cell(row: $0 / 3, column: $0 % 3, bold: $0 < 3, fill: $0 < 3 ? "EDF2FC" : nil)
                })
                let object = SlideObject(kind: .table, x: 110, y: 135, width: 540, height: 168, table: table)
                addObject(object)
                editTable = object
            } label: { Label("表格", systemImage: "tablecells") }
            Spacer(minLength: 3)
            Button {
                if workspaceLayout != .full { workspaceLayout = .full; showNotes = true }
                else { showNotes.toggle() }
            } label: { Label("讲稿", systemImage: showNotes ? "note.text.badge.minus" : "note.text") }
            .tint(notesPanelVisible ? .accentColor : .secondary)
            .buttonStyle(.bordered)
            .background(notesPanelVisible ? Color.accentColor.opacity(0.12) : .clear, in: .rect(cornerRadius: 6))
            .accessibilityAddTraits(notesPanelVisible ? .isSelected : [])
            .help(notesPanelVisible ? "隐藏逐字讲稿" : "显示逐字讲稿")
            .accessibilityIdentifier("toggle-notes-panel")
            Button {
                if workspaceLayout != .full { workspaceLayout = .full; showInspector = true }
                else { showInspector.toggle() }
            } label: { Label("属性", systemImage: "sidebar.right") }
                .tint(inspectorPanelVisible ? .accentColor : .secondary)
                .buttonStyle(.bordered)
                .background(inspectorPanelVisible ? Color.accentColor.opacity(0.12) : .clear, in: .rect(cornerRadius: 6))
                .accessibilityAddTraits(inspectorPanelVisible ? .isSelected : [])
                .fixedSize()
                .help(inspectorPanelVisible ? "隐藏右侧版面属性" : "显示右侧版面属性")
                .accessibilityLabel(inspectorPanelVisible ? "隐藏右侧版面属性" : "显示右侧版面属性")
                .accessibilityIdentifier("toggle-inspector-panel")
            Menu {
                Button("打开课件（切换当前课件）…") { session.chooseFile() }
                Button("追加 PPTX 页面（保留当前课件）…") { importPowerPoint() }
            } label: { Label("导入", systemImage: "square.and.arrow.down") }
            .fixedSize()
            .disabled(importing || session.opening || session.saving)
            .accessibilityIdentifier("import-menu")
            Menu {
                Button("可编辑 PPTX…") {
                    if let window = NSApp.keyWindow {
                        Task { await session.requestSave(asCopy: true, in: window, format: .powerPoint) }
                    }
                }
                Button("投影 PDF…", action: exportProjectionPDF)
                Divider()
                Button("教师讲稿…") { exportTeachingPDF(.teacher) }
                Menu("学生配布稿") {
                    Button("每页 2 张…") { exportTeachingPDF(.studentTwo) }
                    Button("每页 3 张…") { exportTeachingPDF(.studentThree) }
                }
                Divider()
                Menu("所选页") {
                    Button("另存 PPTX…") { exportSelected(selectedPages, format: .powerPoint) }
                    Button("导出 PDF…") { exportSelected(selectedPages, format: .projection) }
                }.disabled(selectedPages.isEmpty)
                Menu("授课资料包") {
                    Button("整份课件…") { exportClassroomPackage() }
                    Button("本章…", action: exportChapterPackage).disabled(slide.section.isEmpty)
                }
                Button("教室兼容 PPTX 副本…") { classroomSheet = .compatibility }
            } label: { Label("导出", systemImage: "square.and.arrow.up") }
            .fixedSize()
            .disabled(importing || session.opening || session.saving || exportBusy)
            .accessibilityIdentifier("export-menu")
            Menu {
                if let file = session.currentDocumentURL {
                    Button(session.isFavorite(file) ? "移除课件收藏" : "收藏此课件") {
                        session.toggleFavorite(file)
                    }
                }
                Section("编辑与排版") {
                    Button("查找与替换…") { classroomSheet = .replace }.keyboardShortcut("f", modifiers: [.command, .shift])
                    Button("批量调整所选页…") { classroomSheet = .batch }.disabled(selectedPages.isEmpty)
                    Button("自动页码与课程页脚…") { classroomSheet = .footer }
                    Button("自定义编辑工具栏…") { classroomSheet = .toolbar }
                    Menu("编辑布局") {
                        ForEach(ClassroomWorkspaceLayout.allCases) { mode in
                            Button(mode.rawValue) { workspaceLayout = mode }
                        }
                    }
                    Button("全文替换字体…") { fontReplacementSheet = true }
                }
                Section("课件检查与恢复") {
                    Button("长课件性能测量…") { classroomSheet = .benchmark }
                    Button("查看打开耗时…") { showOpenTiming = true }.disabled(session.openTiming == nil)
                    Button("查看 PPTX 导入报告") { reviewMode = .imported }
                        .disabled(!deck.slides.contains { $0.importReport != nil })
                    Button("对照原稿 PDF…", action: chooseReferencePDF)
                    Button("课件恢复…") { recoverySheet = true }
                    Button("保存命名快照…", action: saveDeckSnapshot)
                    Button("打开课件快照…", action: openDeckSnapshot)
                }
                Section("课堂与放映") {
                    Button("自定义放映顺序…") { classroomSheet = .shows }
                    Button("课后回顾…") { classroomSheet = .review }.disabled(deck.classroomReview == nil)
                    Button("排练放映并计时…", action: startRehearsal)
                }
            } label: { Label("更多", systemImage: "ellipsis.circle") }
            .fixedSize()
            Button(action: runPreflight) { Label("放映前检查", systemImage: "checklist") }
                .disabled(checkingPreflight)
            Button { startClassroomShow() } label: { Label("放映", systemImage: "play.fill") }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: [.command, .option])
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("幻灯片").font(.headline)
                Spacer()
                Button { pageJumpSheet = true } label: {
                    Text("\(index + 1) / \(deck.slides.count)").monospacedDigit()
                }
                .buttonStyle(.borderless)
                .help("前往指定幻灯片（⌘J）")
                .contextMenu {
                    Button("返回上一浏览页（⌘[）") { stepVisitHistory(backward: true) }
                    Button("前进到下一浏览页（⌘]）") { stepVisitHistory(backward: false) }
                }
                .accessibilityLabel("前往指定幻灯片。当前第 \(index + 1) 页，共 \(deck.slides.count) 页")
                Button { stepEditorPage(-1) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless).disabled(editorPage(-1) == nil)
                    .help("上一页（↑ 或 Page Up）").accessibilityLabel("上一页")
                Button { stepEditorPage(1) } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless).disabled(editorPage(1) == nil)
                    .help("下一页（↓ 或 Page Down）").accessibilityLabel("下一页")
            }
            .padding(.horizontal, 12)
            TextField("搜索标题、正文或讲稿", text: $search)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("sidebar-search")
                .padding(.horizontal, 12)
            Picker("筛选", selection: $slideFilter) {
                ForEach(ClassroomSlideFilter.allCases) { filter in Text(filter.rawValue).tag(filter) }
            }.padding(.horizontal, 12)
            sidebarContext
            sidebarList
            Button { overviewSheet = true } label: { Label("网格总览…", systemImage: "square.grid.2x2") }
                .padding(.horizontal, 12).padding(.bottom, 8)
        }
        .padding(.top, 16)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var filteredSlides: [Slide] {
        deck.slides.filter { slideFilter.includes($0) && (search.isEmpty || SlideSearchHit.first(on: $0, query: search) != nil) }
    }

    private var visibleSlides: [Slide] {
        guard search.isEmpty, slideFilter == .all, !collapsedSections.isEmpty else { return filteredSlides }
        var sectionStart: Slide?
        return deck.slides.filter { row in
            if row.section != sectionStart?.section || sectionStart == nil { sectionStart = row }
            return row.id == sectionStart?.id || (sectionStart.map { !collapsedSections.contains($0.id) } ?? true)
        }
    }

    private func slideRow(_ row: Slide) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            let position = deck.slides.firstIndex { $0.id == row.id } ?? 0
            if !row.section.isEmpty && (!search.isEmpty || position == 0 || deck.slides[position - 1].section != row.section) {
                if search.isEmpty {
                    Button {
                        if collapsedSections.contains(row.id) { collapsedSections.remove(row.id) }
                        else { collapsedSections.insert(row.id) }
                        selectPages([row.id], reveal: false)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: collapsedSections.contains(row.id) ? "chevron.right" : "chevron.down")
                            Text(row.section).lineLimit(1)
                            Spacer(minLength: 0)
                            Text(sectionCount(row.id)).foregroundStyle(.secondary)
                        }
                        .font(.caption.weight(.semibold))
                        .frame(minHeight: 27)
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    .accessibilityIdentifier("sidebar-section-" + row.id.uuidString)
                } else {
                    Text(row.section).font(.caption.weight(.semibold)).lineLimit(1).foregroundStyle(.secondary)
                }
            }
            Button { chooseSidebarPage(row.id) } label: {
                VStack(alignment: .leading, spacing: 5) {
                    SlideSurface(slide: row, images: deck.images, canvas: deck.pageCanvas,
                                 imageCache: imageCache, thumbnail: true)
                        .clipShape(.rect(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(
                            row.id == slide.id ? Color.accentColor : .secondary.opacity(0.24),
                            lineWidth: row.id == slide.id ? 3 : 1))
                        .accessibilityHidden(true)
                    HStack(spacing: 7) {
                        Text(String(format: "%02d", position + 1)).monospacedDigit()
                            .fontWeight(row.id == slide.id ? .bold : .regular)
                            .foregroundStyle(row.id == slide.id ? Color.accentColor : Color.secondary)
                        Text(row.title).lineLimit(1)
                        if row.isBackup {
                            Image(systemName: "eye.slash").foregroundStyle(.secondary)
                                .accessibilityLabel("备用页").help("备用页，顺序放映时跳过")
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.caption)
                    if let hit = SlideSearchHit.first(on: row, query: search) {
                        let snippet = Text(hit.field + " · " + hit.before)
                            + Text(hit.match).bold().foregroundColor(.accentColor)
                            + Text(hit.after)
                        snippet.font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(
                    row.id == slide.id ? Color.accentColor.opacity(0.20) : selectedPages.contains(row.id) ? Color.accentColor.opacity(0.10) : .clear,
                    in: .rect(cornerRadius: 5)
                )
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(row.id == slide.id ? .isSelected : [])
            .accessibilityIdentifier("slide-thumbnail-" + row.id.uuidString)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(ClassroomRowDrag(enabled: canReorderRows, destinationLabel: pageDropTarget == row.id ? dropLocation(row.id) : nil,
                                    after: pageDropAfter,
                                    provider: { startPageDrag(row.id) },
                                    entered: {
                                        if $0 {
                                            pageDropTarget = row.id
                                            pageDropAfter = false
                                            edgeScrollAnchor = row.id
                                        }
                                        else if pageDropTarget == row.id { pageDropTarget = nil }
                                    },
                                    dropped: { dropPage(before: row.id) }))
        .contextMenu {
            let pages = selectedPages.contains(row.id) ? selectedPages : [row.id]
            Button("所选页另存为 PPTX…") { exportSelected(pages, format: .powerPoint) }
            Button("所选页导出为 PDF…") { exportSelected(pages, format: .projection) }
            Menu("移到章节") {
                ForEach(chapterStarts) { chapter in
                    Button(chapter.section) { movePages(pages, to: chapter.id) }
                }
            }.disabled(chapterStarts.isEmpty)
            Divider()
            if pages.count > 1 {
                Button("复制所选 \(pages.count) 页") { duplicateSlides(pages) }
                Button("所选页整体上移") { moveSlides(pages, by: -1) }
                Button("所选页整体下移") { moveSlides(pages, by: 1) }
                Button("删除所选 \(pages.count) 页", role: .destructive) { pendingDeletion = pages }
                Divider()
            }
            let makeBackup = pages.contains { id in deck.slides.first { $0.id == id }?.isBackup == false }
            Button(makeBackup ? "设为备用页" : "设为正片") { setBackup(makeBackup, for: pages) }
            Button("复制此页") { duplicateSlides([row.id]) }
            Button("上移一页") { moveSlide(row.id, delta: -1) }.disabled(row.id == deck.slides.first?.id)
            Button("下移一页") { moveSlide(row.id, delta: 1) }.disabled(row.id == deck.slides.last?.id)
            if !row.section.isEmpty {
                Divider()
                Button("重命名整章…") { renameSection(row.id) }
                Button("上移整章") { moveSection(row.id, delta: -1) }
                    .disabled(adjacentSection(row.id, delta: -1) == nil || !search.isEmpty)
                Button("下移整章") { moveSection(row.id, delta: 1) }
                    .disabled(adjacentSection(row.id, delta: 1) == nil || !search.isEmpty)
            }
            Button("删除此页", role: .destructive) { deleteSlides([row.id]) }
        }
    }

    private var awaitingFirstDraw: Bool {
        if let timing = session.openTiming { return timing.firstDraw == nil }
        return false
    }

    private func firstCanvasDraw(_ time: Double, _ imageTime: Double) {
        Task { @MainActor in session.recordFirstDraw(for: documentIdentity, at: time, imageTime: imageTime) }
    }

    private var workspace: some View {
        GeometryReader { geometry in
            let scale = max(0.1, min((geometry.size.width - 48) / deck.pageCanvas.width,
                                     (geometry.size.height - 48) / deck.pageCanvas.height))
            let actualScale = zoomPercent.map { $0 / 100 } ?? scale
            if zoomPercent == nil {
                canvasWorkspace(scale: actualScale)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    canvasWorkspace(scale: actualScale)
                        .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                }.background(Color(nsColor: .underPageBackgroundColor))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func canvasWorkspace(scale: CGFloat) -> some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)
                .onTapGesture { clearObjectSelection() }
                ZStack(alignment: .topLeading) {
                    SlideSurface(slide: slide, images: deck.images, omittedObject: editingID, hiddenObjects: hiddenObjects, canvas: deck.pageCanvas,
                                 imageCache: imageCache, didDraw: awaitingFirstDraw ? firstCanvasDraw : nil)
                        .accessibilityIdentifier("editor-canvas-" + slide.id.uuidString)
                        .onTapGesture { clearObjectSelection() }
                        .gesture(objectMarqueeGesture(scale: scale))
                        .contextMenu {
                            Button("插入矩形") {
                                addObject(SlideObject(kind: .rectangle, x: 110, y: 170,
                                                      width: 220, height: 100, color: Palette.indigo))
                            }
                            Button("插入直线") { addConnector(arrow: .none) }
                            Button("插入箭头") { addConnector(arrow: .triangle) }
                            Toggle("启用参考线与吸附", isOn: $snapEnabled)
                            Button("显示所有临时隐藏对象") { hiddenObjects = [] }.disabled(hiddenObjects.isEmpty)
                        }
                    ForEach(slide.objects.filter { !$0.isLocked && !hiddenObjects.contains($0.id) }) { object in
                        objectOverlay(object, scale: scale)
                    }
                    if let guide = canvasSnap { canvasGuides(guide, scale: scale) }
                    if let locatedObject, let located = slide.objects.first(where: { $0.id == locatedObject }),
                       !hiddenObjects.contains(located.id) {
                        RoundedRectangle(cornerRadius: 3).strokeBorder(Color.accentColor, style: .init(lineWidth: 3, dash: [6, 3]))
                            .frame(width: located.width * scale, height: located.height * scale)
                            .position(x: located.frame.midX * scale, y: located.frame.midY * scale)
                            .allowsHitTesting(false)
                    }
                    if let objectMarquee {
                        Rectangle().fill(Color.accentColor.opacity(0.10))
                            .overlay(Rectangle().strokeBorder(Color.accentColor, lineWidth: 1))
                            .frame(width: objectMarquee.width * scale, height: objectMarquee.height * scale)
                            .position(x: objectMarquee.midX * scale, y: objectMarquee.midY * scale)
                            .allowsHitTesting(false)
                    }
                    if let selection, editingID == nil, selectedObjects.count < 2, !slide.objects[selection].isLocked, !hiddenObjects.contains(slide.objects[selection].id) {
                        let object = slide.objects[selection]
                        SlideResizeHandles(frame: object.frame, scale: scale, proportional: object.kind == .image) { frame in
                            changeObjectFrame(object.id, to: frame)
                        }
                        .frame(width: deck.pageCanvas.width * scale, height: deck.pageCanvas.height * scale)
                        .id(object.id)
                        .zIndex(2)
                    }
                }
                .frame(width: deck.pageCanvas.width * scale, height: deck.pageCanvas.height * scale)
                .clipped()
                .coordinateSpace(name: "slideCanvas")
                .shadow(color: .black.opacity(0.15), radius: 12, y: 5)
        }
        .frame(minWidth: deck.pageCanvas.width * scale + 32, minHeight: deck.pageCanvas.height * scale + 32)
    }

    private func clearObjectSelection() {
        focusCanvas()
        objectID = nil
        additionalObjects.removeAll()
        editingID = nil
        selectedTextRanges = []
    }

    private func chooseObject(_ id: UUID, extend: Bool = NSEvent.modifierFlags.contains(.shift)) {
        focusCanvas()
        selectedTextRanges = []
        if extend, let current = objectID, current != id {
            if additionalObjects.contains(id) { additionalObjects.remove(id) }
            else { additionalObjects.insert(id) }
        } else {
            objectID = id
            additionalObjects.removeAll()
        }
    }

    private func chooseGroup(_ group: UUID, primary: UUID) {
        chooseObject(primary, extend: false)
        additionalObjects = Set(slide.objects.filter { $0.groupID == group && !$0.isLocked && $0.id != primary }.map(\.id))
    }

    private func regroupObjects() {
        let ids = selectedObjects
        let group = UUID()
        var updated = slide
        guard let first = updated.objects.firstIndex(where: { ids.contains($0.id) }) else { return }
        let members = updated.objects.filter { ids.contains($0.id) }.map { object -> SlideObject in
            var copy = object
            copy.groupID = group
            return copy
        }
        updated.objects.removeAll { ids.contains($0.id) }
        updated.objects.insert(contentsOf: members, at: first)
        document.deck.slides[index] = updated
    }

    private func ungroup(_ group: UUID) {
        var updated = slide
        for index in updated.objects.indices where updated.objects[index].groupID == group {
            updated.objects[index].groupID = nil
        }
        document.deck.slides[index] = updated
    }

    private func objectMarqueeGesture(scale: CGFloat) -> some Gesture {
        func rect(_ drag: DragGesture.Value) -> CGRect {
            CGRect(x: min(drag.startLocation.x, drag.location.x) / scale,
                   y: min(drag.startLocation.y, drag.location.y) / scale,
                   width: abs(drag.translation.width) / scale, height: abs(drag.translation.height) / scale)
        }
        return DragGesture(minimumDistance: 5, coordinateSpace: .named("slideCanvas"))
            .updating($objectMarquee) { drag, frame, _ in frame = rect(drag) }
            .onEnded { drag in
                let selection = slide.objects.filter { !$0.isLocked && rect(drag).intersects($0.frame) }.map(\.id)
                clearObjectSelection()
                objectID = selection.first
                additionalObjects = Set(selection.dropFirst())
            }
    }

    private func moveObjects(dragged id: UUID, by delta: CGSize) {
        if !selectedObjects.contains(id) {
            if let group = slide.objects.first(where: { $0.id == id })?.groupID { chooseGroup(group, primary: id) }
            else { chooseObject(id, extend: false) }
        }
        let selected = selectedObjects
        let members = slide.objects.filter { selected.contains($0.id) }
        guard let left = members.map(\.x).min(), let right = members.map(\.x).max(),
              let top = members.map(\.y).min(), let bottom = members.map(\.y).max() else { return }
        let adjusted = snap(for: id, delta: delta).delta
        let dx = Double(adjusted.width).clamped((-10_000 - left)...(10_000 - right))
        let dy = Double(adjusted.height).clamped((-10_000 - top)...(10_000 - bottom))
        var updated = slide
        for index in updated.objects.indices where selected.contains(updated.objects[index].id) {
            updated.objects[index].x += dx
            updated.objects[index].y += dy
        }
        document.deck.slides[index] = updated
        canvasSnap = nil
    }

    private func alignObjects(horizontal: Bool) {
        let ids = selectedObjects
        var updated = slide
        let members = updated.objects.filter { ids.contains($0.id) }
        let axis = horizontal ? \SlideObject.x : \SlideObject.y
        guard let edge = members.map({ $0[keyPath: axis] }).min() else { return }
        for index in updated.objects.indices where ids.contains(updated.objects[index].id) {
            updated.objects[index][keyPath: axis] = edge
        }
        document.deck.slides[index] = updated
    }

    private func distributeObjects(horizontal: Bool) {
        let ids = selectedObjects
        var updated = slide
        let axis = horizontal ? \SlideObject.x : \SlideObject.y
        let extent = horizontal ? \SlideObject.width : \SlideObject.height
        let order = updated.objects.indices.filter { ids.contains(updated.objects[$0].id) }
            .sorted { updated.objects[$0][keyPath: axis] < updated.objects[$1][keyPath: axis] }
        guard order.count > 2, let first = order.first, let last = order.last else { return }
        let start = updated.objects[first][keyPath: axis]
        let end = updated.objects[last][keyPath: axis] + updated.objects[last][keyPath: extent]
        let occupied = order.reduce(0.0) { $0 + updated.objects[$1][keyPath: extent] }
        let gap = (end - start - occupied) / Double(order.count - 1)
        var position = start
        for member in order {
            guard abs(position) <= 10_000 else { return }
            updated.objects[member][keyPath: axis] = position
            position += updated.objects[member][keyPath: extent] + gap
        }
        document.deck.slides[index] = updated
    }

    @ViewBuilder
    private func objectOverlay(_ object: SlideObject, scale: CGFloat) -> some View {
        let width = CGFloat(object.width) * scale
        let height = CGFloat(object.height) * scale
        if editingID == object.id {
            CanvasTextEditor(object: object, scale: scale, selectAll: selectNewText, edit: { value in
                textBinding(object.id).wrappedValue = value
            }, select: {
                if editingID == object.id { selectedTextRanges = $0 }
            }, finish: {
                if editingID == object.id {
                    editingID = nil
                }
            }, cancel: {
                styleBrush = nil
                editingID = nil
                selectedTextRanges = []
            })
                .id(object.id)
                .background(Color(nsColor: Palette.color(slide.background)))
                .frame(width: width, height: height)
                .overlay(alignment: .topTrailing) { overflowIndicator(object) }
                .overlay(Rectangle().strokeBorder(Color.accentColor, lineWidth: 2).allowsHitTesting(false))
                .position(x: object.x * scale + width / 2, y: object.y * scale + height / 2)
                .zIndex(1)
        } else {
            ObjectHitArea(object: object, selected: objectID == object.id || selectedObjects.contains(object.id), scale: scale,
                          slideBackground: slide.background, images: deck.images, canvas: deck.pageCanvas,
                          select: {
                              if let group = object.groupID, !NSEvent.modifierFlags.contains(.shift) {
                                  chooseGroup(group, primary: object.id)
                              } else {
                                  chooseObject(object.id)
                              }
                          },
                          edit: {
                              chooseObject(object.id, extend: false)
                              if object.kind == .text {
                                  selectNewText = false
                                  editingID = object.id
                              }
                              if object.kind == .table { editTable = object }
                          },
                          guide: { offset in
                              canvasSnap = snap(for: object.id, delta: CGSize(width: offset.width / scale, height: offset.height / scale))
                          },
                          move: { offset in
                              moveObjects(dragged: object.id, by: CGSize(width: offset.width / scale, height: offset.height / scale))
                          })
                .frame(width: width, height: height)
                .overlay(alignment: .topTrailing) { if objectID == object.id { overflowIndicator(object) } }
                .position(x: object.x * scale + width / 2, y: object.y * scale + height / 2)
        }
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 5) {
            Capsule().fill(.secondary.opacity(0.45)).frame(width: 34, height: 4)
                .frame(maxWidth: .infinity)
                .frame(height: 12).contentShape(Rectangle())
                .gesture(DragGesture(coordinateSpace: .global)
                    .updating($notesResize) { drag, value, _ in value = -Double(drag.translation.height) }
                    .onEnded { drag in notesHeight = (notesHeight - Double(drag.translation.height)).clamped(72...260) })
                .accessibilityHidden(true)
            HStack {
                Label("逐字讲稿", systemImage: "note.text").font(.headline)
                Text("第 \(index + 1) 页").font(.caption).foregroundStyle(.secondary)
                if workspaceLayout == .notes {
                    Button("上一页") { stepEditorPage(-1) }.disabled(editorPage(-1) == nil)
                    Button("下一页") { stepEditorPage(1) }.disabled(editorPage(1) == nil)
                }
                Picker("讲解标记", selection: slideBinding(\.teachingCue)) {
                    Text("无").tag(nil as Slide.TeachingCue?)
                    ForEach(Slide.TeachingCue.allCases) { cue in Text(cue.rawValue).tag(Optional(cue)) }
                }.fixedSize()
                Spacer()
                Stepper("\(Int(notesFontSize)) 磅", value: $notesFontSize, in: 12...36)
                Button("专注视图") { notesFocus = true }
                EditorPanelCloseButton(title: "关闭逐字讲稿", identifier: "close-notes-panel") { showNotes = false }
            }
            TextEditor(text: slideBinding(\.speakerNotes))
                .font(.system(size: notesFontSize))
                .scrollContentBackground(.hidden)
                .frame(minHeight: workspaceLayout == .notes ? 240 : (notesHeight + notesResize).clamped(72...260),
                       maxHeight: workspaceLayout == .notes ? .infinity : (notesHeight + notesResize).clamped(72...260))
                .accessibilityLabel("逐字讲稿")
                .accessibilityIdentifier("editor-notes-" + slide.id.uuidString)
        }
        .padding(.horizontal, 12).padding(.bottom, 10)
    }

    private var inspector: some View {
        VStack(spacing: 0) {
            HStack {
                Text(selection.map { slide.objects[$0].kind.inspectorTitle } ?? "页面属性").font(.headline)
                Spacer()
                EditorPanelCloseButton(title: "关闭右侧版面属性", identifier: "close-inspector-panel") {
                    showInspector = false
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            Divider()
            inspectorContents
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var inspectorContents: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        inspectorSelection
                        if selection != nil {
                            DisclosureGroup("页面属性") { pageInspectorControls.padding(.top, 7) }
                        } else { pageInspectorControls }
                    }.padding(14)
                }
                if !slide.objects.isEmpty {
                    Divider()
                    ScrollViewReader { scroll in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 4) { inspectorObjectList }.padding(10)
                        }
                        .onChange(of: objectID) { _, id in
                            if let id { withAnimation(.easeInOut(duration: 0.18)) { scroll.scrollTo(id, anchor: .center) } }
                        }
                    }.frame(height: min(225, max(99, geometry.size.height * 0.36)))
                }
            }
        }.background(Color(nsColor: .controlBackgroundColor))
    }

    private var pageInspectorControls: some View {
        VStack(alignment: .leading, spacing: 9) {
                Button("幻灯片尺寸…") { canvasSheet = true }
                Button("学术引文与出处…") { citationSheet = true }
                Toggle("答案页／仅教师使用", isOn: Binding(get: { slide.teacherOnly == true }, set: {
                    slideBinding(\.teacherOnly).wrappedValue = $0 ? true : nil
                }))
                if slide.originalPDFPage != nil { Button("恢复 PDF 修复前的可编辑对象", action: restorePDFPage) }
                Toggle("课堂书签", isOn: Binding(get: { slide.bookmarked == true },
                                                   set: { slideBinding(\.bookmarked).wrappedValue = $0 ? true : nil }))
                Toggle("备用页", isOn: Binding(get: { slide.isBackup }, set: { setBackup($0, for: [slide.id]) }))
                    .help("顺序放映时跳过，可在放映中手动调出。")
                TextField("章节名称", text: slideBinding(\.section))
                TextField("本章计划（分）", value: chapterMinutes, format: .number)
                    .help("同名连续页共用计划时长，输入 0 清除。")
                colorMenu("页背景", selection: slideBinding(\.background),
                          colors: [("米白", Palette.paper), ("纯白", "FFFFFF"), ("深蓝", Palette.ink), ("淡蓝", "EDF2FC")])
        }
    }

    @ViewBuilder
    private var inspectorSelection: some View {
                if selectedObjects.count > 1 {
                    Text("已选 \(selectedObjects.count) 个对象").font(.headline)
                    if let selection, let group = slide.objects[selection].groupID,
                       slide.objects.filter({ selectedObjects.contains($0.id) }).allSatisfy({ $0.groupID == group }) {
                        Button("解散组合") { ungroup(group) }
                    } else {
                        Button("组合对象") { regroupObjects() }
                    }
                    Menu("对齐与分布") {
                        Button("左对齐") { alignObjects(horizontal: true) }
                        Button("上对齐") { alignObjects(horizontal: false) }
                        Button("水平等距") { distributeObjects(horizontal: true) }.disabled(selectedObjects.count < 3)
                        Button("垂直等距") { distributeObjects(horizontal: false) }.disabled(selectedObjects.count < 3)
                    }
                } else if let selection {
                    let object = slide.objects[selection]
                    Text(object.label).font(.headline).lineLimit(2)
                    if let group = object.groupID {
                        Button("选择整个组合") { chooseGroup(group, primary: object.id) }
                        Button("解散组合") { ungroup(group) }
                    }
                    if let source = object.decorationSource {
                        Text(source.title).font(.caption).foregroundStyle(.secondary)
                    }
                    Button(object.isLocked ? "解锁对象" : "锁定对象") {
                        editingID = nil
                        objectBinding(object.id, \.locked, fallback: nil).wrappedValue = object.isLocked ? nil : true
                    }
                    if !object.isLocked {
                        if object.kind == .text {
                            TextEditor(text: textBinding(object.id))
                                .frame(height: 82)
                                .border(.secondary.opacity(0.22))
                                .accessibilityLabel("文本框内容")
                            Button("局部文字格式…") { formatText = object }.disabled(object.text.isEmpty)
                            number("字号", object: object, key: \.fontSize, range: 8...200)
                            Toggle("粗体", isOn: objectBinding(object.id, \.bold, fallback: false))
                            Menu("文字对齐") {
                                Button("左对齐") { setAlignment(.left, for: object.id) }
                                Button("居中") { setAlignment(.center, for: object.id) }
                                Button("右对齐") { setAlignment(.right, for: object.id) }
                                Button("两端对齐") { setAlignment(.justified, for: object.id) }
                            }
                        }
                        if object.kind == .image {
                            cropControls(object)
                            pictureAppearanceControls(object)
                            HStack {
                                number("宽", object: object, key: \.width, range: 1...1920)
                                number("高", object: object, key: \.height, range: 1...1080)
                            }
                        } else if let table = object.table {
                            Text("\(table.rows.count) 行 × \(table.columns.count) 列").font(.caption)
                            Button("编辑单元格…") { editTable = object }
                        } else {
                            if object.kind == .connector { connectorControls(object) }
                            let colorTitle = object.kind == .text ? "文字颜色" : object.kind == .connector ? "线条颜色" : "填充颜色"
                            colorMenu(colorTitle,
                                      selection: objectBinding(object.id, \.color, fallback: Palette.ink),
                                      colors: [("墨黑", Palette.ink), ("靛蓝", Palette.indigo), ("砖红", "A34E42"),
                                               ("墨绿", "286B61"), ("纯白", "FFFFFF")])
                        }
                        DisclosureGroup("位置、尺寸与层次") {
                            VStack(alignment: .leading, spacing: 8) {
                                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 10) {
                                    GridRow {
                                        number("X", object: object, key: \.x, range: -960...960)
                                        number("Y", object: object, key: \.y, range: -540...540)
                                    }
                                    if object.kind != .image {
                                        GridRow {
                                            number("宽", object: object, key: \.width, range: 1...1920)
                                            number("高", object: object, key: \.height, range: 1...1080)
                                        }
                                    }
                                }
                                HStack {
                                    Button("置顶") { changeLayer(object.id, front: true) }
                                    Button("置底") { changeLayer(object.id, front: false) }
                                }
                            }.padding(.top, 6)
                        }
                        Button("删除对象", role: .destructive) { removeObject(object.id) }
                    }
                }
    }

    @ViewBuilder
    private var inspectorObjectList: some View {
                if !slide.objects.isEmpty {
                    Text("对象").font(.headline)
                    ForEach(slide.objects.reversed()) { object in
                        Button {
                            chooseObject(object.id, extend: !object.isLocked && NSEvent.modifierFlags.contains(.shift))
                            locateOnCanvas(object)
                        } label: {
                            HStack(spacing: 6) {
                                Text(object.label).lineLimit(1)
                                Spacer(minLength: 0)
                                if object.isLocked { Image(systemName: "lock.fill").help("已锁定") }
                                if hiddenObjects.contains(object.id) { Image(systemName: "eye.slash").help("临时隐藏") }
                                if object.teacherOnly == true { Image(systemName: "person.fill").help("教师专用") }
                            }
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .padding(5)
                        .id(object.id)
                        .background(objectID == object.id ? Color.accentColor.opacity(0.12) : .clear,
                                    in: .rect(cornerRadius: 4))
                        .contextMenu {
                            Button("重命名对象…") { objectName = object.objectName ?? ""; renameTarget = object }
                            Button(hiddenObjects.contains(object.id) ? "显示对象" : "临时隐藏对象") {
                                if !hiddenObjects.insert(object.id).inserted { hiddenObjects.remove(object.id) }
                                if objectID == object.id { clearObjectSelection() }
                            }
                            Toggle("教师专用批注", isOn: Binding(get: { object.teacherOnly == true }, set: {
                                objectBinding(object.id, \.teacherOnly, fallback: nil).wrappedValue = $0 ? true : nil
                            }))
                        }
                        .draggable(object.id.uuidString)
                        .dropDestination(for: String.self) { values, _ in
                            guard let value = values.first, let id = UUID(uuidString: value) else { return false }
                            return moveLayer(id, onto: object.id)
                        }
                    }
                }
    }

    private func addConnector(arrow: SlideConnector.Arrow) {
        if let line = SlideConnector.object(from: CGPoint(x: 110, y: 175), to: CGPoint(x: 315, y: 175),
                                            style: SlideConnector(endArrow: arrow), color: Palette.indigo) {
            addObject(line)
        }
    }

    private func connectorControls(_ object: SlideObject) -> some View {
        let binding = objectBinding(object.id, \.connector, fallback: nil)
        func field<Value>(_ path: WritableKeyPath<SlideConnector, Value>) -> Binding<Value> {
            Binding(get: { (binding.wrappedValue ?? .init())[keyPath: path] },
                    set: { value in
                        guard var line = binding.wrappedValue else { return }
                        line[keyPath: path] = value
                        if line.isValid { binding.wrappedValue = line }
                    })
        }
        return VStack(alignment: .leading, spacing: 6) {
            Picker("起点箭头", selection: field(\.startArrow)) {
                ForEach(SlideConnector.Arrow.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("终点箭头", selection: field(\.endArrow)) {
                ForEach(SlideConnector.Arrow.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("线型", selection: field(\.dash)) {
                ForEach(SlideConnector.Dash.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            connectorAttachmentPicker(object, start: true)
            connectorAttachmentPicker(object, start: false)
            TextField("线宽", value: field(\.weight), format: .number.precision(.fractionLength(0...2)))
                .help("线宽为 0.25 至 96 磅")
            Grid(alignment: .leading, horizontalSpacing: 8) {
                GridRow {
                    connectorEndpoint("起点 X", object: object, start: true, horizontal: true)
                    connectorEndpoint("起点 Y", object: object, start: true, horizontal: false)
                }
                GridRow {
                    connectorEndpoint("终点 X", object: object, start: false, horizontal: true)
                    connectorEndpoint("终点 Y", object: object, start: false, horizontal: false)
                }
            }
        }
    }

    private func connectorAttachmentPicker(_ object: SlideObject, start: Bool) -> some View {
        let targets = Array(slide.objects.enumerated().filter { $0.element.kind == .rectangle })
        let field = objectBinding(object.id, \.connector, fallback: nil)
        let selection = Binding<UUID?>(get: {
            let line = field.wrappedValue
            return (start ? line?.startAttachment : line?.endAttachment)?.objectID
        }, set: { id in
            guard var line = field.wrappedValue,
                  let current = slide.objects.first(where: { $0.id == object.id }) else { return }
            let ends = line.endpoints(in: current.frame)
            let link = targets.first(where: { $0.element.id == id }).map {
                SlideConnector.Attachment.nearest(on: $0.element, to: start ? ends.start : ends.end)
            }
            if start { line.startAttachment = link } else { line.endAttachment = link }
            field.wrappedValue = line
        })
        return Picker(start ? "起点连接" : "终点连接", selection: selection) {
            Text("自由端点").tag(nil as UUID?)
            ForEach(targets, id: \.element.id) { item in
                Text("矩形 · 对象 \(item.offset + 1)").tag(Optional(item.element.id))
            }
        }
    }

    private func connectorEndpoint(_ title: String, object: SlideObject, start: Bool, horizontal: Bool) -> some View {
        let field = Binding<Double>(
            get: {
                guard let current = slide.objects.first(where: { $0.id == object.id }),
                      let line = current.connector else { return 0 }
                let ends = line.endpoints(in: current.frame)
                let point = start ? ends.start : ends.end
                return horizontal ? point.x : point.y
            },
            set: { value in
                guard let position = slide.objects.firstIndex(where: { $0.id == object.id }),
                      let line = slide.objects[position].connector else { return }
                let current = slide.objects[position]
                var ends = line.endpoints(in: current.frame)
                let axis: WritableKeyPath<CGPoint, CGFloat> = horizontal ? \.x : \.y
                if start { ends.start[keyPath: axis] = value } else { ends.end[keyPath: axis] = value }
                var style = line
                if start { style.startAttachment = nil } else { style.endAttachment = nil }
                guard let updated = SlideConnector.object(from: ends.start, to: ends.end, style: style, color: current.color) else { return }
                var next = current
                next.x = updated.x
                next.y = updated.y
                next.width = updated.width
                next.height = updated.height
                next.connector = updated.connector
                document.deck.slides[index].objects[position] = next
            }
        )
        return VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, value: field, format: .number.precision(.fractionLength(0...2)))
                .labelsHidden().textFieldStyle(.roundedBorder)
        }
    }

    private func pictureAppearanceControls(_ object: SlideObject) -> some View {
        let appearance = objectBinding(object.id, \.pictureAppearance, fallback: nil)
        func field<Value>(_ path: WritableKeyPath<PictureAppearance, Value>) -> Binding<Value> {
            Binding(get: { (appearance.wrappedValue ?? .init())[keyPath: path] },
                    set: { value in
                        var updated = appearance.wrappedValue ?? .init()
                        updated[keyPath: path] = value
                        if updated.isValid { appearance.wrappedValue = updated == .init() ? nil : updated }
                    })
        }
        return VStack(alignment: .leading, spacing: 6) {
            TextField("旋转角度", value: field(\.angle), format: .number.precision(.fractionLength(0...1)))
                .help("输入 −360 至 360 度，正数为顺时针。")
            Slider(value: field(\.opacity), in: 0...1, step: 0.01) {
                Text("不透明度")
            }.help("不透明度")
            Text((field(\.opacity).wrappedValue).formatted(.percent.precision(.fractionLength(0))))
                .font(.caption).foregroundStyle(.secondary)
            Toggle("水平翻转", isOn: field(\.flipHorizontal))
            Toggle("垂直翻转", isOn: field(\.flipVertical))
            Button("重置旋转、翻转和透明度") { appearance.wrappedValue = nil }
        }
    }

    private func cropControls(_ object: SlideObject) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Menu("图片裁剪") {
                Button("等比适应图片") { setPictureFit(object, fill: false) }
                Button("等比填充画框") { setPictureFit(object, fill: true) }
                Button("重置裁剪") { objectBinding(object.id, \.pictureCrop, fallback: nil).wrappedValue = nil }
            }
            Grid(alignment: .leading) {
                GridRow { cropField("左", object, \.left, opposite: \.right)
                    cropField("右", object, \.right, opposite: \.left) }
                GridRow { cropField("上", object, \.top, opposite: \.bottom)
                    cropField("下", object, \.bottom, opposite: \.top) }
            }
        }
    }

    private func cropField(_ label: String, _ object: SlideObject, _ edge: WritableKeyPath<PictureCrop, Double>,
                           opposite: KeyPath<PictureCrop, Double>) -> some View {
        HStack(spacing: 3) {
            Text(label).foregroundStyle(.secondary)
            TextField(label, value: Binding(
                get: { (slide.objects.first { $0.id == object.id }?.pictureCrop ?? .init())[keyPath: edge] },
                set: { value in
                    guard let position = slide.objects.firstIndex(where: { $0.id == object.id }) else { return }
                    var area = slide.objects[position].pictureCrop ?? .init()
                    area[keyPath: edge] = value.clamped(0...max(0, 0.99 - area[keyPath: opposite]))
                    document.deck.slides[index].objects[position].pictureCrop = area == .init() ? nil : area
                }), format: .percent.precision(.fractionLength(0...1)))
                .labelsHidden().textFieldStyle(.roundedBorder).frame(minWidth: 45)
        }
    }

    private func setPictureFit(_ object: SlideObject, fill: Bool) {
        guard let id = object.imageID, let data = deck.images[id], let image = SlideDrawing.picture(data),
              let position = slide.objects.firstIndex(where: { $0.id == object.id }) else { return }
        let size = CGSize(width: CGFloat(image.width), height: CGFloat(image.height))
        var updated = object
        if fill {
            let area = PictureCrop.filling(image: size, frame: object.frame.size)
            updated.pictureCrop = area == .init() ? nil : area
        } else {
            let scale = min(object.width / size.width, object.height / size.height)
            let width = max(1, size.width * scale)
            let height = max(1, size.height * scale)
            updated.x = object.frame.midX - width / 2
            updated.y = object.frame.midY - height / 2
            updated.width = width
            updated.height = height
            updated.pictureCrop = nil
        }
        if updated != object { document.deck.slides[index].objects[position] = updated }
    }

    private func changeObjectFrame(_ id: UUID, to frame: CGRect) {
        guard let position = slide.objects.firstIndex(where: { $0.id == id }) else { return }
        var object = slide.objects[position]
        guard object.frame != frame else { return }
        object.x = Double(frame.minX).clamped(-10_000...10_000)
        object.y = Double(frame.minY).clamped(-10_000...10_000)
        object.width = frame.width
        object.height = frame.height
        document.deck.slides[index].objects[position] = object
    }

    private func number(_ label: String, object: SlideObject,
                        key: WritableKeyPath<SlideObject, Double>, range: ClosedRange<Double>) -> some View {
        let binding = objectBinding(object.id, key, fallback: object[keyPath: key])
        return HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            TextField(label, value: Binding(
                get: { binding.wrappedValue },
                set: { binding.wrappedValue = $0.clamped(range) }
            ), format: .number.precision(.fractionLength(0...1)))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 52)
        }
    }

    private func colorMenu(_ title: String, selection: Binding<String>,
                           colors: [(String, String)]) -> some View {
        Picker(title, selection: selection) {
            ForEach(colors, id: \.1) { color in Text(color.0).tag(color.1) }
        }
    }

    private func slideBinding<Value>(_ key: WritableKeyPath<Slide, Value>) -> Binding<Value> {
        Binding(get: { slide[keyPath: key] }, set: { document.deck.slides[index][keyPath: key] = $0 })
    }

    private func setAlignment(_ alignment: SlideParagraph.Alignment, for id: UUID) {
        guard let position = slide.objects.firstIndex(where: { $0.id == id }) else { return }
        var object = slide.objects[position]
        object.formatParagraphs(in: []) { _, paragraph in paragraph.alignment = alignment }
        document.deck.slides[index].objects[position] = object
    }

    private func textBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { slide.objects.first { $0.id == id }?.text ?? "" },
            set: { value in
                guard let position = slide.objects.firstIndex(where: { $0.id == id }) else { return }
                var object = slide.objects[position]
                object.replaceText(with: value)
                document.deck.slides[index].objects[position] = object
            }
        )
    }

    private func objectBinding<Value>(_ id: UUID, _ key: WritableKeyPath<SlideObject, Value>,
                                      fallback: Value) -> Binding<Value> {
        Binding(
            get: { slide.objects.first { $0.id == id }?[keyPath: key] ?? fallback },
            set: { value in
                guard let i = slide.objects.firstIndex(where: { $0.id == id }) else { return }
                document.deck.slides[index].objects[i][keyPath: key] = value
            }
        )
    }

    private func addSlide(_ newSlide: Slide) {
        var next = newSlide
        next.objects = next.objects.map { SlideCanvas.widescreen.fitting($0, into: deck.pageCanvas) }
        next.section = slide.section
        document.deck.slides.insert(next, at: index + 1)
        selectPages([next.id])
    }

    private static let pagePasteboard = NSPasteboard.PasteboardType("com.kongslides.clipboard.slides")
    private static let objectPasteboard = NSPasteboard.PasteboardType("com.kongslides.clipboard.object")

    private func focusCanvas() {
        pageCommands = false
        if let window = NSApp.keyWindow, window.firstResponder is NSTextView {
            window.makeFirstResponder(nil)
        }
    }

    private func applyPageJump() {
        guard let page = pendingJump else { return }
        pendingJump = nil
        guard deck.slides.indices.contains(page - 1) else { return }
        let id = deck.slides[page - 1].id
        selectPages([id])
    }

    private func editorPage(_ direction: Int) -> UUID? {
        deck.editorPage(after: index, direction: direction,
                        matching: search.isEmpty && slideFilter == .all ? nil : Set(filteredSlides.map(\.id)))
    }

    private func stepEditorPage(_ direction: Int) {
        if let target = editorPage(direction) { selectPages([target]) }
    }

    private func stepVisitHistory(backward: Bool) {
        guard let page = visitHistory.step(from: slide.id, backward: backward, available: Set(deck.slides.map(\.id))) else { return }
        activatePages(SidebarPageSelection(current: page, selected: [page], anchor: page),
                      reveal: true, recordVisit: false)
    }

    private func handleShortcut(_ event: NSEvent) -> Bool {
        guard session.screen == .editor else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if modifiers.isEmpty, event.keyCode == 53 {
            if styleBrush != nil { styleBrush = nil; return true }
            if editingID != nil { editingID = nil; selectedTextRanges = []; return true }
        }
        if modifiers.isEmpty {
            switch event.keyCode {
            case 116, 126: stepEditorPage(-1); return true
            case 121, 125: stepEditorPage(1); return true
            case 115, 119:
                let pages = filteredSlides
                let target = event.keyCode == 115 ? pages.first : pages.last
                if let target { selectPages([target.id]) }
                return true
            default: break
            }
        }
        let pages = selectedPages.isEmpty ? [slide.id] : selectedPages
        if modifiers.isEmpty, [51, 117].contains(event.keyCode) {
            if pageCommands { pendingDeletion = pages; return true }
            if let objectID { removeObject(objectID); return true }
        }
        guard modifiers == .command else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c":
            return copySelection(pages)
        case "v":
            return pasteSelection()
        case "d":
            if pageCommands { duplicateSlides(pages); return true }
            guard let selection else { return false }
            let box = SlideClipboard(slides: [Slide(objects: [slide.objects[selection]])], images: deck.images, canvas: deck.pageCanvas)
            insert(box, at: index, asObject: true)
            return true
        case "[", "]":
            stepVisitHistory(backward: event.charactersIgnoringModifiers == "[")
            return true
        case "a":
            guard pageCommands else { return false }
            selectedPageIDs = Set(visibleSlides.map(\.id))
            return true
        default:
            return false
        }
    }

    private func copySelection(_ pages: Set<UUID>) -> Bool {
        let payload: SlideClipboard
        let type: NSPasteboard.PasteboardType
        if pageCommands {
            payload = SlideClipboard(slides: deck.slides.filter { pages.contains($0.id) }, images: deck.images, canvas: deck.pageCanvas)
            type = Self.pagePasteboard
        } else {
            guard let selection else { return false }
            payload = SlideClipboard(slides: [Slide(objects: [slide.objects[selection]])], images: deck.images, canvas: deck.pageCanvas)
            type = Self.objectPasteboard
        }
        guard let data = try? JSONEncoder().encode(payload) else { return false }
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setData(data, forType: type)
    }

    private func pasteSelection() -> Bool {
        let clipboard = NSPasteboard.general
        let type = pageCommands ? Self.pagePasteboard : Self.objectPasteboard
        guard let data = clipboard.data(forType: type), data.count <= 192 * 1024 * 1024 else { return false }
        do {
            let contents = try JSONDecoder().decode(SlideClipboard.self, from: data).validated()
            let last = deck.slides.lastIndex { selectedPages.contains($0.id) } ?? index
            insert(contents, at: pageCommands ? last + 1 : index, asObject: !pageCommands)
        } catch { linkedError = "剪贴板中的 KongSlides 内容无法读取。" }
        return true
    }

    private func insert(_ clipboard: SlideClipboard, at position: Int, asObject: Bool) {
        var updated = deck
        let copies = clipboard.copies(into: &updated)
        if asObject {
            guard copies.count == 1, var object = copies.first?.objects.first, copies.first?.objects.count == 1 else { return }
            object.x = (object.x + 12).clamped(-10_000...10_000)
            object.y = (object.y + 12).clamped(-10_000...10_000)
            updated.slides[index].objects.append(object)
            document.deck = updated
            objectID = object.id
        } else {
            updated.slides.insert(contentsOf: copies, at: position)
            document.deck = updated
            search = ""
            selectPages(copies.map(\.id))
        }
    }

    private func chooseSidebarPage(_ id: UUID) {
        let modifiers = NSEvent.modifierFlags
        let command = modifiers.contains(.command)
        let shift = modifiers.contains(.shift)
        let mode: SidebarPageSelection.Click = shift ? (command ? .extendRange : .range) : (command ? .toggle : .single)
        let visible = visibleSlides.map(\.id)
        var selection = SidebarPageSelection(current: slide.id,
                                             selected: selectedPages.isEmpty ? [slide.id] : selectedPages,
                                             anchor: pageSelectionAnchor ?? slide.id)
        selection.click(id, in: visible, mode: mode)
        activatePages(selection, reveal: false)
    }

    private func selectPages(_ ids: [UUID], reveal: Bool = true) {
        guard let first = ids.first else { return }
        activatePages(SidebarPageSelection(current: first, selected: Set(ids), anchor: first), reveal: reveal)
    }

    private func activatePages(_ selection: SidebarPageSelection, reveal: Bool, recordVisit: Bool = true) {
        if recordVisit { visitHistory.visit(from: slide.id, to: selection.current) }
        if let window = NSApp.keyWindow, window.firstResponder is NSTextView {
            window.makeFirstResponder(nil)
        }
        selectedPageIDs = selection.selected
        pageSelectionAnchor = selection.anchor
        slideID = selection.current
        session.rememberPage(selection.current, for: documentIdentity)
        objectID = nil
        additionalObjects.removeAll()
        editingID = nil
        pageCommands = true
        if reveal { pageToReveal = selection.current }
    }

    private func duplicateSlides(_ ids: Set<UUID>) {
        let pages = deck.slides.filter { ids.contains($0.id) }
        guard let last = deck.slides.lastIndex(where: { ids.contains($0.id) }) else { return }
        insert(SlideClipboard(slides: pages, images: deck.images, canvas: deck.pageCanvas), at: last + 1, asObject: false)
    }

    private func deleteSlides(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        var updated = deck
        let current = slide.id
        updated.slides.removeAll { ids.contains($0.id) }
        if updated.slides.isEmpty { updated.slides = [Slide()] }
        let next = updated.slides.first { $0.id == current } ?? updated.slides[min(index, updated.slides.count - 1)]
        document.deck = (try? updated.validated()) ?? updated
        selectPages([next.id])
    }

    private func moveSlides(_ ids: Set<UUID>, by delta: Int) {
        var updated = deck
        updated.moveSelectedSlides(ids, by: delta)
        if updated.slides != deck.slides { document.deck = updated }
    }

    private func renameSection(_ id: UUID) {
        guard let range = sectionRange(id) else { return }
        let alert = NSAlert()
        alert.messageText = "重命名章节"
        let input = NSTextField(string: deck.slides[range.lowerBound].section)
        input.frame = CGRect(x: 0, y: 0, width: 265, height: 25)
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        alert.addButton(withTitle: "重命名")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var updated = deck
        for position in range { updated.slides[position].section = name }
        document.deck = updated
    }

    private func moveSlide(_ id: UUID, delta: Int) {
        guard let position = deck.slides.firstIndex(where: { $0.id == id }),
              deck.slides.indices.contains(position + delta) else { return }
        let current = slide.id
        document.deck.slides.swapAt(position, position + delta)
        slideID = current
    }

    private func reorderOverviewPage(_ source: UUID, _ target: UUID) -> Bool {
        guard source != target, let start = deck.slides.firstIndex(where: { $0.id == source }),
              let end = deck.slides.firstIndex(where: { $0.id == target }) else { return false }
        reorder(from: IndexSet(integer: start), to: end > start ? end + 1 : end)
        return true
    }

    private func reorder(from offsets: IndexSet, to destination: Int) {
        let current = slide.id
        document.deck.slides.move(fromOffsets: offsets, toOffset: destination)
        slideID = current
    }

    private func addObject(_ object: SlideObject) {
        document.deck.slides[index].objects.append(object)
        objectID = object.id
        pageCommands = false
    }

    private func insertTextBox() {
        let object = SlideCanvas.widescreen.fitting(SlideObject(), into: deck.pageCanvas)
        editingID = nil
        additionalObjects.removeAll()
        selectedTextRanges = []
        selectNewText = true
        addObject(object)
        editingID = object.id
    }

    private func formatSelectedText(_ transform: (inout SlideObject) -> Void) {
        guard var object = formattingObject, let selection else { return }
        let oldText = object.text
        transform(&object)
        if oldText != object.text { selectedTextRanges = [] }
        document.deck.slides[index].objects[selection] = object
    }

    private func changeLayer(_ id: UUID, front: Bool) {
        guard let position = slide.objects.firstIndex(where: { $0.id == id }) else { return }
        var updated = slide
        let object = updated.objects.remove(at: position)
        updated.objects.insert(object, at: front ? updated.objects.count : 0)
        document.deck.slides[index] = updated
    }

    private func removeObject(_ id: UUID) {
        guard slide.objects.first(where: { $0.id == id })?.isLocked != true else { return }
        var updated = deck
        updated.slides[index].objects.removeAll { $0.id == id }
        if objectID == id { objectID = nil }
        document.deck = (try? updated.validated()) ?? updated
    }

    private func moveSection(_ id: UUID, delta: Int) {
        guard let source = sectionRange(id),
              let adjacent = adjacentSection(id, delta: delta) else { return }
        let current = slide.id
        document.deck.slides.move(fromOffsets: IndexSet(integersIn: source),
                                  toOffset: delta < 0 ? adjacent.lowerBound : adjacent.upperBound)
        slideID = current
    }

    private func sectionRange(_ id: UUID) -> Range<Int>? {
        guard let position = deck.slides.firstIndex(where: { $0.id == id }) else { return nil }
        let section = deck.slides[position].section
        var first = position
        var last = position + 1
        while first > 0 && deck.slides[first - 1].section == section { first -= 1 }
        while last < deck.slides.count && deck.slides[last].section == section { last += 1 }
        return first..<last
    }

    private func adjacentSection(_ id: UUID, delta: Int) -> Range<Int>? {
        guard let range = sectionRange(id) else { return nil }
        let boundary = delta < 0 ? range.lowerBound - 1 : range.upperBound
        guard deck.slides.indices.contains(boundary) else { return nil }
        return sectionRange(deck.slides[boundary].id)
    }

    private func addImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = PhotoStorage.thumbnail(source),
                  let png = PhotoStorage.png(image) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let scale = min(460.0 / Double(image.width), 295.0 / Double(image.height), 1.0)
            let id = UUID()
            let object = SlideObject(kind: .image, x: 135, y: 150,
                                     width: max(1, Double(image.width) * scale),
                                     height: max(1, Double(image.height) * scale), imageID: id)
            var updated = deck
            updated.images[id] = png
            updated.slides[index].objects.append(object)
            document.deck = updated
            objectID = object.id
            pageCommands = false
        } catch { linkedError = "无法读取这张图片。\n\(error.localizedDescription)" }
    }

    private func importPowerPoint() {
        let panel = NSOpenPanel()
        let legacy = UTType(filenameExtension: "ppt")
        panel.allowedContentTypes = [.slidePowerPoint] + [legacy].compactMap { $0 }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadPowerPoint(url)
    }

    private func loadPowerPoint(_ url: URL) {
        guard !importing else { return }
        importing = true
        let status = ImportProgress()
        importProgress = status
        let task = Task.detached(priority: .userInitiated) {
            try PowerPoint.readForEditor(url) { completed, total in
                Task { @MainActor in
                    status.completed = max(status.completed, completed)
                    status.total = total
                }
            }
        }
        importTask = task
        Task { @MainActor in
            defer { importing = false; importTask = nil }
            do {
                let imported = try await task.value
                guard !task.isCancelled else { return }
                var updated = deck
                let title = url.deletingPathExtension().lastPathComponent
                updated.slides.append(contentsOf: imported.deck.fitted(to: deck.pageCanvas).slides.map { original in
                    var copy = original
                    copy.section = title
                    return copy
                })
                updated.images.merge(imported.deck.images, uniquingKeysWith: { current, _ in current })
                document.deck = updated
                search = ""
                selectPages(Array(imported.deck.slides.prefix(1).map(\.id)))

                reviewMode = .imported
            } catch {
                if !task.isCancelled { linkedError = "无法导入这份 PPTX。\n\(error.localizedDescription)" }
            }
        }
    }

    private var chapterMinutes: Binding<Int> {
        Binding(get: {
            guard let range = sectionRange(slide.id) else { return 0 }
            return deck.slides[range.lowerBound].plannedChapterMinutes ?? 0
        }, set: { value in
            guard let range = sectionRange(slide.id), (0...600).contains(value) else { return }
            document.deck.slides[range.lowerBound].plannedChapterMinutes = value == 0 ? nil : value
        })
    }

    private func startRehearsal() {
        if !presenter.start(deck: deck, at: 0, onRehearsalFinished: { chapters in
            guard session.identity == documentIdentity else { return }
            rehearsedChapters = chapters
            rehearsalSheet = true
        }) {
            linkedError = "课件中只有备用页。请先将至少一页设为正片。"
        }
    }

    private func saveDeckSnapshot() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.kongSlides]
        panel.nameFieldStringValue = session.name + "-快照"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.resolvingSymlinksInPath().standardizedFileURL != session.fileURL?.resolvingSymlinksInPath().standardizedFileURL else {
            linkedError = "请选择与当前课件不同的快照文件名。"
            return
        }
        let snapshot = document
        Task {
            do { try await Task.detached(priority: .userInitiated) { try snapshot.writeNative(to: url) }.value }
            catch { linkedError = error.localizedDescription }
        }
    }

    private func openDeckSnapshot() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.kongSlides]
        panel.prompt = "预览"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let deck = try await Task.detached(priority: .userInitiated) { try SlidesDocument.readNative(url).deck }.value
                guard session.identity == documentIdentity else { return }
                savedSnapshot = DeckSnapshot(url: url, deck: deck)
            } catch { linkedError = error.localizedDescription }
        }
    }

    private func chooseReferencePDF() { chooseReferencePDF(for: slide.id) }

    private func chooseReferencePDF(for slideID: UUID) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.prompt = "对照"
        if panel.runModal() == .OK, let url = panel.url { referencePDF = ReferenceFile(url: url, selectedSlide: slideID) }
    }

    private func replaceWithReference(_ slideID: UUID, page: Int, url: URL) {
        let identity = documentIdentity
        Task { @MainActor in
            do {
                let rendered = try await Task.detached(priority: .userInitiated) {
                    guard let pdf = CGPDFDocument(url as CFURL) else { throw ReferencePDFError.unavailable }
                    let image = try ReferencePDF.image(in: pdf, page: page)
                    guard let data = PhotoStorage.png(image) else { throw ReferencePDFError.invalidPage }
                    return (data, CGSize(width: image.width, height: image.height))
                }.value
                guard session.identity == identity,
                      let index = deck.slides.firstIndex(where: { $0.id == slideID }) else { return }
                var updated = deck
                let asset = UUID()
                updated.images[asset] = rendered.0
                ReferencePDF.replace(&updated.slides[index], with: asset, size: rendered.1, canvas: updated.pageCanvas,
                                     repair: .init(pdfName: url.lastPathComponent, pdfPage: page + 1))
                document.deck = try updated.validated()
                search = ""
                selectPages([slideID])
            } catch { linkedError = error.localizedDescription }
        }
    }

    private func reviewPanel(_ mode: SlideReviewMode) -> some View {
        SlideReviewPanel(
            mode: mode,
            rows: mode == .imported ? SlideReviewRow.imported(deck) : currentPreflightRows,
            pageCount: mode == .imported ? deck.slides.filter { $0.importReport != nil }.count : preflightPageCount,
            currentPage: index + 1,
            checking: mode == .preflight && checkingPreflight,
            refresh: runPreflight,
            compare: chooseReferencePDF,
            repair: { chooseReferencePDF(for: $0.slideID) },
            exportReport: exportImportReport,
            fonts: { fontReplacementSheet = true },
            close: { reviewMode = nil },
            reveal: { row in
                guard let target = deck.slides.first(where: { $0.id == row.slideID }) else { return }
                search = ""
                editingID = nil
                selectPages([target.id])
                objectID = target.objects.first { $0.id == row.objectID }?.id
                pageCommands = objectID == nil
            }
        )
    }

    private func exportImportReport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "tsv") ?? .plainText]
        panel.nameFieldStringValue = "\(session.name)-导入问题.tsv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Data(SlideReviewRow.exportTSV(deck).utf8).write(to: url, options: .atomic) }
        catch { linkedError = error.localizedDescription }
    }

    private var currentPreflightRows: [SlideReviewRow] {
        let pageNumber = Dictionary(uniqueKeysWithValues: deck.slides.enumerated().map { ($0.element.id, $0.offset + 1) })
        return preflightRows.compactMap { row in
            guard let page = pageNumber[row.slideID] else { return nil }
            var current = row
            current.page = page
            return current
        }
    }

    private func runPreflight() {
        reviewMode = .preflight
        guard !checkingPreflight else { return }
        let snapshot = deck
        checkingPreflight = true
        preflightRows = []
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) { SlideReviewRow.preflight(snapshot) }.value
            preflightRows = result
            if session.identity == documentIdentity {
                session.recordPreflight(affectedPages: Set(result.map(\.slideID)).count)
            }
            preflightPageCount = snapshot.slides.count
            checkingPreflight = false
        }
    }

    private func saveCurrentTemplate() {
        let alert = NSAlert()
        alert.messageText = "保存当前页为教学版式"
        alert.informativeText = "版式会保存对象、图片和样式。将它用于提纲生成时，按从上到下、从左到右的顺序选用前两个文本框放置标题和正文。"
        let field = NSTextField(string: slide.title)
        field.frame = CGRect(x: 0, y: 0, width: 285, height: 25)
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { linkedError = "请输入版式名称。"; return }
        do {
            try templateStore.save(TeachingTemplate(name: name, slide: slide, images: deck.images, canvas: deck.pageCanvas))
        } catch { linkedError = "无法保存教学版式。\n\(error.localizedDescription)" }
    }

    private func setBackup(_ enabled: Bool, for ids: Set<UUID>) {
        var updated = deck
        for position in updated.slides.indices where ids.contains(updated.slides[position].id) {
            updated.slides[position].hiddenInShow = enabled ? true : nil
        }
        if updated != deck { document.deck = updated }
    }

    private func backupExportOption(for panel: NSSavePanel) -> NSButton? {
        guard deck.slides.contains(where: \.isBackup) else { return nil }
        let checkbox = NSButton(checkboxWithTitle: "包含备用页", target: nil, action: nil)
        checkbox.state = .off
        checkbox.setFrameSize(checkbox.fittingSize)
        panel.accessoryView = checkbox
        return checkbox
    }

    private func exportChapterPackage() {
        guard !slide.section.isEmpty, let range = sectionRange(slide.id) else { return }
        exportClassroomPackage(section: range, chapter: slide.section)
    }

    private func exportClassroomPackage(section: Range<Int>? = nil, chapter: String? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "导出到此处"
        guard panel.runModal() == .OK, let location = panel.url else { return }
        var snapshot = deck
        if let section { snapshot.slides = Array(snapshot.slides[section]) }
        let name = chapter.map { session.name + "-" + $0 } ?? session.name
        let exportDeck = snapshot
        Task { @MainActor in
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try TeachingPDF.chapterPackage(exportDeck, title: name, in: location, includeEditable: section == nil)
                }.value
                exportReceipt = .init(url: result)
            } catch { exportReceipt = .init(url: location, success: false, report: [error.localizedDescription]) }
        }
    }

    private func exportTeachingPDF(_ format: TeachingPDF.Format) {
        if format != .teacher {
            classroomSheet = format == .studentTwo ? .studentTwo : .studentThree
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(session.name)-\(format.label).pdf"
        let backupOption = format == .teacher ? nil : backupExportOption(for: panel)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let includeBackups = backupOption?.state == .on
        let snapshot = deck
        Task { @MainActor in
            do {
                try await Task.detached(priority: .userInitiated) {
                    try TeachingPDF.write(snapshot, format: format, includeBackups: includeBackups, to: url)
                }.value
                exportReceipt = .init(url: url)
            } catch { exportReceipt = .init(url: url, success: false, report: [error.localizedDescription]) }
        }
    }

    private func exportProjectionPDF() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = session.name + ".pdf"
        let backupOption = backupExportOption(for: panel)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let includeBackups = backupOption?.state == .on
        let input = deck
        writeExport(at: url) {
            try SlideDrawing.pdf(input, includeBackups: includeBackups, to: url)
            return nil
        }
    }
    @ViewBuilder
    private func classroomTool(_ tool: ClassroomToolSheet) -> some View {
        switch tool {
        case .replace:
            let chapter = sectionRange(slide.id).map { Set(deck.slides[$0].map(\.id)) } ?? [slide.id]
            ReplaceDeckTextView(deck: deck, current: slide.id, chapter: chapter) { matches, replacement in
                var changed = deck
                changed.replace(matches, with: replacement)
                document.deck = changed
            }
        case .batch:
            let pages = selectedPages
            let ordered = deck.slides.filter { pages.contains($0.id) }.map(\.id)
            BatchSlideStyleView(deck: deck, pages: ordered) { size, color, background, footer in
                var changed = deck
                changed.applyBatchStyle(to: pages, titleSize: size, bodyColor: color, background: background, showFooter: footer)
                document.deck = changed
            }
        case .footer:
            CourseFooterView(deck: deck, current: index, apply: { document.deck.courseFooter = $0 },
                             settings: deck.courseFooter ?? .init(course: session.name), enabled: deck.courseFooter != nil)
        case .shows:
            ClassroomShowLibrary(deck: deck, selected: deck.slides.filter { selectedPages.contains($0.id) }.map(\.id),
                                 update: { document.deck.classroomShows = $0 }, start: { show in
                Task { @MainActor in startClassroomShow(show) }
            }, shows: deck.classroomShows ?? [])
        case .review:
            if let review = deck.classroomReview {
                ClassroomReviewView(review: review, deck: deck) { id in
                    document.deck.classroomReview?.resumePage = id
                    slideFilter = .all
                    search = ""
                    selectPages([id])
                }
            }
        case .compatibility:
            ClassroomCompatibilityView(deck: deck) { fonts, replacement, pages in
                Task { @MainActor in await exportCompatibility(fonts: fonts, replacement: replacement, flattened: pages) }
            }
        case .studentTwo, .studentThree:
            let format: TeachingPDF.Format = tool == .studentTwo ? .studentTwo : .studentThree
            StudentHandoutPreview(deck: deck, format: format) { data in
                Task { @MainActor in await saveHandout(data, title: format.label) }
            }
        case .benchmark: PerformanceBenchmarkView(deck: deck)
        case .toolbar: FormattingToolbarSettings()
        }
    }

    private func startClassroomShow(_ show: ClassroomShow? = nil) {
        let sourceID = documentIdentity
        let resume = deck.classroomReview?.resumePage
        let start = resume.flatMap { page in deck.slides.firstIndex { $0.id == page } } ?? index
        if !presenter.start(deck: deck, at: start, show: show, onReview: { review in
            guard session.identity == sourceID else { return }
            document.deck.classroomReview = review
        }) {
            linkedError = show == nil ? "请先将至少一页设为正片。" : "所选放映方案里没有可放映的页面。"
        }
    }

    private func useStyleBrush() {
        guard let object = formattingObject else { return }
        let ranges = selectedTextRanges.filter { !$0.isEmpty && $0.upperBound <= object.text.utf16.count }
        if let paint = styleBrush {
            formatSelectedText { target in
                target.formatCharacters(in: ranges) { run in
                    run.size = paint.size
                    run.bold = paint.bold
                    run.color = paint.color
                    run.fontName = paint.fontName
                    run.usesSystemFont = !ranges.isEmpty && paint.fontName == nil ? true : paint.usesSystemFont
                    run.baseline = paint.baseline
                    run.characterStyle = paint.characterStyle
                }
            }
            styleBrush = nil
        } else {
            var copied = object.formattingStyles(in: ranges).first ?? object.baseTextStyle
            copied.size = copied.size ?? object.fontSize
            if copied.usesSystemFont != true { copied.fontName = copied.fontName ?? object.textLayout?.fontName }
            styleBrush = copied
        }
    }

    private func snap(for id: UUID, delta: CGSize) -> CanvasSnap {
        guard snapEnabled, !NSEvent.modifierFlags.contains(.option),
              let object = slide.objects.first(where: { $0.id == id }) else { return .init(delta: delta) }
        let moving = selectedObjects.contains(id) ? selectedObjects : [id]
        let frame = slide.objects.filter { moving.contains($0.id) }.reduce(CGRect.null) { $0.union($1.frame) }
        let anchors = slide.objects.filter { !moving.contains($0.id) && !hiddenObjects.contains($0.id) && $0.isCourseFooter != true }.map(\.frame)
        return CanvasSnap.move(frame.isNull ? object.frame : frame, by: delta,
                               anchors: anchors + [CGRect(origin: .zero, size: deck.pageCanvas.size)], tolerance: 6)
    }

    @ViewBuilder
    private func overflowIndicator(_ object: SlideObject) -> some View {
        if object.kind == .text && SlideText.isClipped(object) {
            Menu {
                Button("增高文本框") { repairOverflow(object.id, action: .grow) }
                Button("缩小字号") { repairOverflow(object.id, action: .shrink) }
                Button("拆到续页") { repairOverflow(object.id, action: .split) }
            } label: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).padding(3)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("文本溢出。选择处理方式。")
            .accessibilityLabel("处理文本溢出")
            .offset(x: object.frame.maxX < deck.pageCanvas.width - 15 ? 10 : -1,
                    y: object.y > 18 ? -14 : -2)
        }
    }

    private func repairOverflow(_ id: UUID, action: ClassroomOverflowAction) {
        guard let position = slide.objects.firstIndex(where: { $0.id == id }) else { return }
        var revised = deck
        let object = slide.objects[position]
        switch action {
        case .grow:
            var changed = object
            let limit = max(changed.height, deck.pageCanvas.height - changed.y - 8)
            while SlideText.isClipped(changed) && changed.height < limit { changed.height = min(limit, changed.height + 14) }
            revised.slides[index].objects[position] = changed
        case .shrink:
            var changed = object
            while SlideText.isClipped(changed) && changed.fontSize > 8 {
                let next = max(8, changed.fontSize - 1)
                changed.formatCharacters(in: []) { $0.size = max(8, min(next, $0.size ?? next)) }
            }
            revised.slides[index].objects[position] = changed
        case .split:
            guard let divided = SlideText.splitOverflow(object, continuationHeight: deck.pageCanvas.height - 48) else {
                linkedError = "当前文本框无法容纳完整文字。请先加高文本框或缩小字号。"
                return
            }
            revised.slides[index].objects[position] = divided.first
            var continuation = slide
            continuation.id = UUID()
            continuation.objects = divided.continuations
            continuation.speakerNotes = ""
            continuation.bookmarked = nil
            continuation.importReport = nil
            continuation.originalPDFPage = nil
            var pages: [Slide] = []
            for object in divided.continuations {
                var page = continuation
                page.id = UUID()
                page.objects = [object]
                pages.append(page)
            }
            revised.slides.insert(contentsOf: pages, at: index + 1)
        }
        document.deck = revised
    }

    private func moveLayer(_ id: UUID, onto target: UUID) -> Bool {
        guard id != target, let source = slide.objects.firstIndex(where: { $0.id == id && $0.isCourseFooter != true }),
              let destination = slide.objects.firstIndex(where: { $0.id == target && $0.isCourseFooter != true }) else { return false }
        document.deck.slides[index].objects.move(fromOffsets: IndexSet(integer: source),
                                                   toOffset: destination > source ? destination + 1 : destination)
        return true
    }

    private func restorePDFPage() {
        guard let original = slide.originalPDFPage else { return }
        var changed = deck
        changed.slides[index].background = original.background
        changed.slides[index].objects = original.objects
        changed.slides[index].importReport?.repair = original.previousRepair
        changed.slides[index].originalPDFPage = nil
        do { document.deck = try changed.validated() }
        catch { linkedError = error.localizedDescription }
    }

    private var chapterStarts: [Slide] {
        deck.slides.enumerated().compactMap { index, page in
            guard !page.section.isEmpty, index == 0 || deck.slides[index - 1].section != page.section else { return nil }
            return page
        }
    }

    private func movePages(_ ids: Set<UUID>, to chapter: UUID) {
        guard !ids.contains(chapter), let range = sectionRange(chapter) else { return }
        var changed = deck
        let section = changed.slides[range.lowerBound].section
        let anchor = changed.slides[range].last(where: { !ids.contains($0.id) })?.id ?? chapter
        var moved = changed.slides.filter { ids.contains($0.id) }
        for index in moved.indices { moved[index].section = section }
        changed.slides.removeAll { ids.contains($0.id) }
        guard let destination = changed.slides.firstIndex(where: { $0.id == anchor }) else { return }
        changed.slides.insert(contentsOf: moved, at: destination + 1)
        document.deck = changed
        search = ""
        slideFilter = .all
        selectPages(moved.map(\.id))
    }

    private var canReorderRows: Bool { search.isEmpty && slideFilter == .all && collapsedSections.isEmpty }

    private func startPageDrag(_ id: UUID) -> NSItemProvider {
        draggingPage = id
        edgeScrollAnchor = id
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: classroomSlideDragType, visibility: .ownProcess) { complete in
            complete(Data(id.uuidString.utf8), nil)
            return nil
        }
        return provider
    }

    private func dropPage(before destination: UUID, after: Bool = false) -> Bool {
        defer { stopPageDrag() }
        guard let source = draggingPage, source != destination,
              let first = deck.slides.firstIndex(where: { $0.id == source }),
              let target = deck.slides.firstIndex(where: { $0.id == destination }) else { return false }
        reorder(from: IndexSet(integer: first), to: target + (after ? 1 : 0))
        return true
    }

    private func stopPageDrag() {
        edgeScroll?.cancel()
        edgeScroll = nil
        draggingPage = nil
        pageDropTarget = nil
        pageDropAfter = false
        edgeScrollAnchor = nil
    }

    private func scrollEdge(_ side: VerticalEdge, using proxy: ScrollViewProxy) -> some View {
        Rectangle().fill(Color.accentColor.opacity(0.1)).frame(height: 18).contentShape(Rectangle())
            .onDrop(of: [classroomSlideDragType], delegate: ClassroomDropHandler(entered: { near in
                edgeScroll?.cancel()
                edgeScroll = nil
                guard near, let draggingPage else { return }
                let direction = side == .top ? -1 : 1
                let pages = deck.slides.map(\.id)
                guard var cursor = pages.firstIndex(of: edgeScrollAnchor ?? draggingPage) else { return }
                edgeScroll = Task { @MainActor in
                    while !Task.isCancelled {
                        let next = cursor + direction
                        guard pages.indices.contains(next) else { return }
                        cursor = next
                        edgeScrollAnchor = pages[cursor]
                        pageDropTarget = pages[cursor]
                        pageDropAfter = side == .bottom
                        withAnimation(.linear(duration: 0.13)) { proxy.scrollTo(pages[cursor], anchor: side == .top ? .top : .bottom) }
                        try? await Task.sleep(for: .milliseconds(155))
                    }
                }
            }, dropped: {
                guard let edgeScrollAnchor else { stopPageDrag(); return false }
                return dropPage(before: edgeScrollAnchor, after: side == .bottom)
            }))
            .accessibilityHidden(true)
    }

    private func exportTarget(format: UTType, name: String) async -> URL? {
        guard let window = session.editorWindow, !exportBusy, !session.saving else { return nil }
        exportBusy = true
        defer { exportBusy = false }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format]
        panel.nameFieldStringValue = name
        panel.directoryURL = session.currentDocumentURL?.deletingLastPathComponent()
        let response = await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
        return response == .OK ? panel.url : nil
    }

    private func exportSelected(_ ids: Set<UUID>, format: ClassroomExportFormat) {
        let copy = deck.selectingPages(ids)
        guard !copy.slides.isEmpty else { return }
        Task { @MainActor in
            guard let url = await exportTarget(format: format.contentType, name: session.name + "-选中页") else { return }
            writeExport(at: url) {
                switch format {
                case .powerPoint:
                    try PowerPoint.write(copy, to: url)
                    return ClassroomExport.checkPowerPoint(copy, at: url)
                case .projection:
                    try SlideDrawing.pdf(copy, includeBackups: true, to: url)
                    return nil
                }
            }
        }
    }

    private func exportCompatibility(fonts: [String], replacement: String?, flattened: Set<UUID>) async {
        let input = deck
        guard let url = await exportTarget(format: .slidePowerPoint, name: session.name + "-教室兼容副本") else { return }
        writeExport(at: url) {
            let copy = try ClassroomExport.compatibilityCopy(input, sources: fonts, replacement: replacement, flatten: flattened)
            try PowerPoint.write(copy, to: url)
            return ClassroomExport.checkPowerPoint(copy, at: url)
        }
    }

    private func saveHandout(_ data: Data, title: String) async {
        guard let url = await exportTarget(format: .pdf, name: session.name + "-" + title) else { return }
        writeExport(at: url) {
            try data.write(to: url, options: .atomic)
            return nil
        }
    }

    private func writeExport(at url: URL, _ operation: @escaping () throws -> PowerPointAudit?) {
        guard !exportBusy else { return }
        exportBusy = true
        Task { @MainActor in
            defer { exportBusy = false }
            do {
                let report = try await Task.detached(priority: .userInitiated) {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    return try operation()
                }.value
                exportReceipt = .init(url: url, audit: report)
            } catch {
                exportReceipt = .init(url: url, success: false, report: [error.localizedDescription])
            }
        }
    }

    private var notesPanelVisible: Bool { workspaceLayout == .notes || (workspaceLayout == .full && showNotes) }
    private var inspectorPanelVisible: Bool { workspaceLayout == .full && showInspector }

    private func panelWidthBadge(_ width: Double) -> some View {
        Text("\(Int(width.rounded())) 点").font(.caption.monospacedDigit())
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(.regularMaterial, in: .rect(cornerRadius: 4))
            .fixedSize().offset(y: 5).allowsHitTesting(false)
    }

    private var editorStatusBar: some View {
        HStack(spacing: 10) {
            Group {
                if session.saving || exportBusy {
                    ProgressView().controlSize(.small)
                    Text("正在保存或导出…")
                } else if session.isEdited {
                    Label("有未保存的修改", systemImage: "circle.dotted")
                } else if session.fileURL != nil {
                    Label("已保存", systemImage: "checkmark.circle")
                } else {
                    Label("尚未保存", systemImage: "circle.dotted")
                }
            }.accessibilityIdentifier("saving-deck")
            if let receipt = exportReceipt { statusReceipt(receipt) }
            Spacer(minLength: 5)
            Text("第 \(index + 1)/\(deck.slides.count) 页").monospacedDigit()
                .accessibilityIdentifier("status-current-page")
            if !selectedObjects.isEmpty {
                Text(editingID == nil ? "已选 \(selectedObjects.count) 个对象" : "编辑文字")
                    .help(editingID == nil ? "Delete 删除所选对象。" : "Delete 删除文字；Esc 返回选择对象。")
            }
            if workspaceLayout != .notes {
                Divider().frame(height: 15)
                Button("适合窗口") { zoomPercent = nil }.tint(zoomPercent == nil ? .accentColor : .secondary)
                Button("100%") { zoomPercent = 100 }
                Slider(value: Binding(get: { zoomPercent ?? 100 }, set: { zoomPercent = $0 }), in: 25...200, step: 5)
                    .controlSize(.small).frame(width: 85).accessibilityLabel("画布缩放")
                Text(zoomPercent.map { "\(Int($0))%" } ?? "适合").monospacedDigit().frame(width: 38)
            }
        }
        .font(.caption).padding(.horizontal, 12).padding(.vertical, 5)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func statusReceipt(_ receipt: ExportReceipt) -> some View {
        HStack(spacing: 5) {
            Image(systemName: receipt.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(receipt.success ? Color.accentColor : Color.orange)
            Text(receipt.success ? receipt.url.lastPathComponent : receipt.report.first ?? "写入未完成")
                .lineLimit(1).help(receipt.url.path).accessibilityIdentifier("export-result")
            if receipt.success {
                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([receipt.url]) }
            }
            Button("详情") { detailedReceipt = receipt }
            EditorPanelCloseButton(title: "关闭写入结果", identifier: "close-export-receipt") { exportReceipt = nil }
        }
    }

    private var sidebarContext: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let chapter = sidebarVisibleChapter.flatMap({ id in deck.slides.first { $0.id == id } }) ?? (slide.section.isEmpty ? nil : slide),
               !chapter.section.isEmpty {
                Label(chapter.section, systemImage: "rectangle.split.3x1").lineLimit(1)
            }
            if slideFilter != .all || !search.isEmpty {
                let filtered = filteredSlides
                HStack(spacing: 4) {
                    Text("\(slideFilter == .all ? "搜索" : slideFilter.rawValue) · \(filtered.count)/\(deck.slides.count) 页").lineLimit(1)
                    Spacer(minLength: 0)
                    Button {
                        search = ""
                        slideFilter = .all
                        pageToReveal = slide.id
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }.buttonStyle(.plain).accessibilityLabel("清除搜索和筛选")
                }
                if !filtered.contains(where: { $0.id == slide.id }) { Text("当前页在筛选范围外") }
            }
            if let target = pageDropTarget {
                Text(dropLocation(target)).foregroundStyle(Color.accentColor)
            }
        }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12)
    }

    private var sidebarList: some View {
        ScrollViewReader { scroll in
            List {
                ForEach(visibleSlides) { row in
                    slideRow(row).id(row.id).background {
                        GeometryReader { geometry in
                            Color.clear.preference(key: SidebarRowPositions.self,
                                                   value: [row.id: geometry.frame(in: .named("sidebar-viewport")).minY])
                        }.allowsHitTesting(false)
                    }
                }.onMove(perform: canReorderRows ? reorder : nil)
            }
            .listStyle(.sidebar)
            .coordinateSpace(name: "sidebar-viewport")
            .accessibilityIdentifier("sidebar-list")
            .onPreferenceChange(SidebarRowPositions.self) { positions in
                let visible = positions.filter { $0.value >= -8 }.min { $0.value < $1.value }?.key
                sidebarVisibleChapter = visible
            }
            .overlay(alignment: .top) { if draggingPage != nil { scrollEdge(.top, using: scroll) } }
            .overlay(alignment: .bottom) { if draggingPage != nil { scrollEdge(.bottom, using: scroll) } }
            .onChange(of: pageToReveal) { _, target in
                guard let target else { return }
                if let range = sectionRange(target) {
                    let header = deck.slides[range.lowerBound].id
                    if header != target, collapsedSections.remove(header) != nil { return }
                }
                scroll.scrollTo(target, anchor: .center)
                pageToReveal = nil
            }
            .onChange(of: collapsedSections) {
                if let target = pageToReveal {
                    scroll.scrollTo(target, anchor: .center)
                    pageToReveal = nil
                }
            }
        }
    }

    private func dropLocation(_ id: UUID) -> String {
        "移到第 \(positionForRow(id)) 页\(pageDropAfter ? "之后" : "之前")"
    }

    private func positionForRow(_ id: UUID) -> Int { (deck.slides.firstIndex(where: { $0.id == id }) ?? 0) + 1 }

    private func sectionCount(_ id: UUID) -> String {
        sectionRange(id).map { "\($0.count) 页" } ?? ""
    }

    @ViewBuilder
    private func canvasGuides(_ guide: CanvasSnap, scale: CGFloat) -> some View {
        if let x = guide.x {
            Rectangle().fill(Color.accentColor).frame(width: 1, height: deck.pageCanvas.height * scale)
                .position(x: x * scale, y: deck.pageCanvas.height * scale / 2).allowsHitTesting(false)
            guideLabel(guide.xLabel).position(x: x * scale, y: 15).allowsHitTesting(false)
        }
        if let y = guide.y {
            Rectangle().fill(Color.accentColor).frame(width: deck.pageCanvas.width * scale, height: 1)
                .position(x: deck.pageCanvas.width * scale / 2, y: y * scale).allowsHitTesting(false)
            guideLabel(guide.yLabel).position(x: 45, y: y * scale).allowsHitTesting(false)
        }
        if !guide.xSpacing.isEmpty || !guide.ySpacing.isEmpty {
            Path { path in
                let rulerY = max(7, deck.pageCanvas.height * scale - 24)
                for range in guide.xSpacing {
                    let low = range.lowerBound * scale
                    let high = range.upperBound * scale
                    path.move(to: CGPoint(x: low, y: rulerY))
                    path.addLine(to: CGPoint(x: high, y: rulerY))
                    for x in [low, high] {
                        path.move(to: CGPoint(x: x, y: rulerY - 4))
                        path.addLine(to: CGPoint(x: x, y: rulerY + 4))
                    }
                }
                let rulerX = max(7, deck.pageCanvas.width * scale - 24)
                for range in guide.ySpacing {
                    let low = range.lowerBound * scale
                    let high = range.upperBound * scale
                    path.move(to: CGPoint(x: rulerX, y: low))
                    path.addLine(to: CGPoint(x: rulerX, y: high))
                    for y in [low, high] {
                        path.move(to: CGPoint(x: rulerX - 4, y: y))
                        path.addLine(to: CGPoint(x: rulerX + 4, y: y))
                    }
                }
            }.stroke(Color.accentColor, style: .init(lineWidth: 1.4, dash: [3, 2])).allowsHitTesting(false)
        }
    }

    private func guideLabel(_ title: String?) -> some View {
        Text(title ?? "对齐").font(.caption2.bold())
            .padding(.horizontal, 5).padding(.vertical, 3)
            .background(.regularMaterial, in: .rect(cornerRadius: 4)).fixedSize()
    }

    private func locateOnCanvas(_ object: SlideObject) {
        locateTask?.cancel()
        locatedObject = object.id
        locateTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            if !Task.isCancelled { locatedObject = nil }
        }
    }

}

private struct SidebarRowPositions: PreferenceKey {
    static let defaultValue: [UUID: CGFloat] = [:]
    static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newer in newer })
    }
}

private struct ReferenceFile: Identifiable {
    var id: URL { url }
    let url: URL
    let selectedSlide: UUID
}

private enum TeachingSheet: String, Identifiable {
    case outline, templates
    var id: Self { self }
}

@Observable
final class ImportProgress {
    var completed = 0
    var total: Int?
}

extension PowerPoint {
    static func readForEditor(_ url: URL, imageTime: ((Double) -> Void)? = nil,
                              progress: ((Int, Int) -> Void)? = nil) throws -> ImportedDeck {
        try read(url, fontAvailable: { SlideFonts.named($0, size: 12) != nil }, progress: progress) { data in
            let start = OpenTiming.now
            defer { imageTime?(OpenTiming.now - start) }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = PhotoStorage.thumbnail(source) else { return nil }
            return PhotoStorage.png(image)
        }
    }
}

private enum PhotoStorage {
    static func thumbnail(_ source: CGImageSource) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048
        ] as CFDictionary)
    }

    static func png(_ image: CGImage) -> Data? {
        guard let data = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

private struct ObjectHitArea: View {
    let object: SlideObject
    let selected: Bool
    let scale: CGFloat
    let slideBackground: String
    let images: [UUID: Data]
    let canvas: SlideCanvas
    let select: () -> Void
    let edit: () -> Void
    let guide: (CGSize) -> Void
    let move: (CGSize) -> Void
    @GestureState private var translation: CGSize? = nil

    var body: some View {
        Rectangle()
            .fill(.clear)
            .contentShape(Rectangle())
            .overlay {
                if translation != nil {
                    Canvas { graphics, _ in
                        var local = object
                        local.x = 0
                        local.y = 0
                        graphics.withCGContext { context in
                            context.translateBy(x: 0, y: canvas.height * scale)
                            context.scaleBy(x: scale, y: -scale)
                            SlideDrawing.draw(Slide(background: slideBackground, objects: [local]),
                                              images: images, in: context, canvas: canvas)
                        }
                    }
                    .clipped()
                }
                if selected || translation != nil {
                    Rectangle().strokeBorder(Color.accentColor, lineWidth: 2)
                }
            }
            .onTapGesture(count: 2, perform: edit)
            .onTapGesture(perform: select)
            .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("slideCanvas"))
                .updating($translation) { drag, state, _ in state = drag.translation }
                .onChanged { guide($0.translation) }
                .onEnded { drag in move(drag.translation) })
            .offset(translation ?? .zero)
            .accessibilityLabel(object.label)
    }
}

private extension Double {
    func clamped(_ range: ClosedRange<Double>) -> Double {
        isFinite ? min(range.upperBound, max(range.lowerBound, self)) : range.lowerBound
    }
}
