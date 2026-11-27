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
    var canvas: SlideCanvas = .widescreen

    var body: some View {
        Canvas { graphics, size in
            graphics.withCGContext { context in
                var visible = slide
                if let omittedObject { visible.objects.removeAll { $0.id == omittedObject } }
                context.translateBy(x: 0, y: size.height)
                context.scaleBy(x: size.width / canvas.width, y: -size.height / canvas.height)
                SlideDrawing.draw(visible, images: images, in: context, canvas: canvas)
            }
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
    @State private var selectedPageIDs: Set<UUID> = []
    @State private var pageSelectionAnchor: UUID?
    @State private var pageToReveal: UUID?
    @State private var visitHistory = SlideVisitHistory()
    @State private var pageJumpSheet = false
    @State private var overviewSheet = false
    @State private var citationSheet = false
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
    @ObservedObject private var templateStore = TeachingTemplateStore.shared
    @AppStorage("speakerNotesFontSize") private var notesFontSize = 16.0
    @State private var notesHeight = 108.0
    @GestureState private var notesResize = 0.0
    @State private var objectID: UUID?
    @State private var editingID: UUID?
    @State private var linkedError: String?
    @State private var reviewMode: SlideReviewMode?
    @State private var preflightRows: [SlideReviewRow] = []
    @State private var preflightPageCount = 0
    @State private var checkingPreflight = false
    @State private var importing = false
    @State private var importTask: Task<PowerPoint.ImportedDeck, Error>?
    @State private var importProgress = ImportProgress()
    @State private var showNotes = true
    @AppStorage("sidebarWidth") private var sidebarWidth = 206.0
    @GestureState private var sidebarDrag = 0.0
    @State private var search = ""
    @State private var presenter = PresentationController()
    @FocusState private var canvasTextFocused: Bool

    private var deck: Deck { document.deck }
    private var index: Int { deck.slides.firstIndex { $0.id == slideID } ?? 0 }
    private var slide: Slide { deck.slides[index] }
    private var selectedPages: Set<UUID> { selectedPageIDs.intersection(deck.slides.map(\.id)) }
    private var selection: Int? { slide.objects.firstIndex { $0.id == objectID } }

    var body: some View {
        VStack(spacing: 0) {
            controls
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
            HStack(spacing: 0) {
                sidebar.frame(width: (sidebarWidth + sidebarDrag).clamped(168...360))
                Rectangle().fill(Color(nsColor: .separatorColor))
                    .frame(width: 1)
                    .padding(.horizontal, 3)
                    .contentShape(Rectangle())
                    .help("拖动调整缩略图栏宽度")
                    .gesture(DragGesture(coordinateSpace: .global)
                        .updating($sidebarDrag) { value, live, _ in live = value.translation.width }
                        .onEnded { sidebarWidth = (sidebarWidth + $0.translation.width).clamped(168...360) })
                VStack(spacing: 0) {
                    workspace
                    if showNotes {
                        Divider()
                        notes
                    }
                    if let reviewMode {
                        Divider()
                        reviewPanel(reviewMode)
                    }
                }
                Divider()
                inspector.frame(width: 230)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .background(EditorKeyMonitor(handle: handleShortcut))
        .onAppear {
            if slideID == nil, session.identity == documentIdentity,
               let page = session.activePageID, deck.slides.contains(where: { $0.id == page }) {
                slideID = page
                selectedPageIDs = [page]
                pageSelectionAnchor = page
                if deck.slides.first?.id != page { pageToReveal = page }
            }
            if deck.importedTitle != nil && deck.slides.contains(where: { $0.importReport != nil }) {
                reviewMode = .imported
            }
            if RecoverySession.shared.shouldOffer() { recoverySheet = true }
        }
        .onDisappear {
            importTask?.cancel()
            recoveryPending?.cancel()
            RecoverySession.shared.close(recoveryID)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !importing, urls.count == 1, let url = urls.first,
                  url.isFileURL, ["kongslides", "pptx", "ppt"].contains(url.pathExtension.lowercased()) else { return false }
            session.open(url)
            return true
        }
        .onChange(of: session.pageJumpRequest) { pageJumpSheet = true }
        .sheet(isPresented: $citationSheet) {
            let page = slide.id
            SlideCitationView(citation: slide.citation ?? .init()) { updated in
                if let index = deck.slides.firstIndex(where: { $0.id == page }) {
                    document.deck.slides[index].citation = updated == .init() ? nil : updated
                }
            }
        }
        .sheet(isPresented: $overviewSheet) {
            SlideOverview(deck: deck, current: slide.id, open: { id in
                search = ""
                selectPages([id])
            }, reorder: reorderOverviewPage, setBackup: setBackup)
        }
        .sheet(isPresented: $pageJumpSheet, onDismiss: applyPageJump) {
            PageJumpView(currentPage: index + 1, pageCount: deck.slides.count) { pendingJump = $0 }
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
            editingID = nil
        }
        .onChange(of: objectID) { if editingID != objectID { editingID = nil } }
        .onChange(of: canvasTextFocused) { if !canvasTextFocused { editingID = nil } }
        .alert("操作未完成", isPresented: Binding(
            get: { linkedError != nil || session.error != nil },
            set: { if !$0 { linkedError = nil; session.error = nil } }
        )) {
            Button("好", role: .cancel) { linkedError = nil; session.error = nil }
        } message: { Text(linkedError ?? session.error ?? "") }

    }

    private var controls: some View {
        HStack(spacing: 13) {
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
            Button { addObject(SlideObject()) } label: { Label("文字", systemImage: "textformat") }
            Button(action: addImage) { Label("图片", systemImage: "photo") }
            Menu {
                Button("矩形") {
                    addObject(SlideObject(kind: .rectangle, x: 110, y: 170,
                                          width: 220, height: 100, color: Palette.indigo))
                }
                Button("直线") { addConnector(arrow: .none) }
                Button("箭头") { addConnector(arrow: .triangle) }
            } label: { Label("形状", systemImage: "rectangle") }
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
                showNotes.toggle()
            } label: { Label("讲稿", systemImage: showNotes ? "note.text.badge.minus" : "note.text") }
            Menu {
                Button("打开课件…") { session.chooseFile() }.disabled(importing || session.opening)
                Button("追加 PPTX 页面到当前课件…") { importPowerPoint() }.disabled(importing || session.opening)
                Button("查看 PPTX 导入报告") { reviewMode = .imported }
                    .disabled(!deck.slides.contains { $0.importReport != nil })
                Button("对照原稿 PDF…", action: chooseReferencePDF)
                Button("全文替换字体…") { fontReplacementSheet = true }
                Button("课件恢复…") { recoverySheet = true }
                Divider()
                Button("导出可编辑 PPTX…") { export(.powerPoint) }
                Button("导出投影 PDF…") { export(.pdf) }
                Button("导出整份课件的授课资料…") { exportClassroomPackage() }
                Button("导出本章授课资料…", action: exportChapterPackage)
                    .disabled(slide.section.isEmpty)
                Menu("导出讲稿与配布 PDF") {
                    Button("教师讲稿版…") { exportTeachingPDF(.teacher) }
                    Button("学生配布版 · 每页 2 张…") { exportTeachingPDF(.studentTwo) }
                    Button("学生配布版 · 每页 3 张…") { exportTeachingPDF(.studentThree) }
                }
            } label: { Label(importing ? "正在导入" : "交换文件", systemImage: "arrow.left.arrow.right") }
            .fixedSize()
            Button(action: runPreflight) { Label("放映前检查", systemImage: "checklist") }
                .disabled(checkingPreflight)
            Button {
                if !presenter.start(deck: deck, at: index) {
                    linkedError = "课件中只有备用页。请先将至少一页设为正片。"
                }
            } label: { Label("放映", systemImage: "play.fill") }
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
                .padding(.horizontal, 12)
            ScrollViewReader { scroll in
                List {
                    ForEach(visibleSlides) { row in
                        slideRow(row).id(row.id)
                    }
                    .onMove(perform: search.isEmpty && collapsedSections.isEmpty ? reorder : nil)
                }
                .listStyle(.sidebar)
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
            Button { overviewSheet = true } label: { Label("网格总览…", systemImage: "square.grid.2x2") }
                .padding(.horizontal, 12).padding(.bottom, 8)
        }
        .padding(.top, 16)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var filteredSlides: [Slide] {
        guard !search.isEmpty else { return deck.slides }
        return deck.slides.filter { SlideSearchHit.first(on: $0, query: search) != nil }
    }

    private var visibleSlides: [Slide] {
        guard search.isEmpty, !collapsedSections.isEmpty else { return filteredSlides }
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
                        Label(row.section, systemImage: collapsedSections.contains(row.id) ? "chevron.right" : "chevron.down")
                            .font(.caption.weight(.semibold)).lineLimit(1)
                    }.buttonStyle(.plain)
                } else {
                    Text(row.section).font(.caption.weight(.semibold)).lineLimit(1).foregroundStyle(.secondary)
                }
            }
            Button { chooseSidebarPage(row.id) } label: {
                VStack(alignment: .leading, spacing: 5) {
                    SlideSurface(slide: row, images: deck.images, canvas: deck.pageCanvas)
                        .clipShape(.rect(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(
                            row.id == slide.id ? Color.accentColor : .secondary.opacity(0.24),
                            lineWidth: row.id == slide.id ? 2 : 1))
                        .accessibilityHidden(true)
                    HStack(spacing: 7) {
                        Text(String(format: "%02d", position + 1)).monospacedDigit().foregroundStyle(.secondary)
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
                    selectedPages.contains(row.id) || row.id == slide.id ? Color.accentColor.opacity(0.14) : .clear,
                    in: .rect(cornerRadius: 5)
                )
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(row.id == slide.id ? .isSelected : [])
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            let pages = selectedPages.contains(row.id) ? selectedPages : [row.id]
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

    private var workspace: some View {
        GeometryReader { geometry in
            let scale = max(0.1, min((geometry.size.width - 48) / deck.pageCanvas.width,
                                     (geometry.size.height - 48) / deck.pageCanvas.height))
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                    .onTapGesture { focusCanvas(); objectID = nil; editingID = nil }
                ZStack(alignment: .topLeading) {
                    SlideSurface(slide: slide, images: deck.images, omittedObject: editingID, canvas: deck.pageCanvas)
                        .onTapGesture { focusCanvas(); objectID = nil; editingID = nil }
                    ForEach(slide.objects.filter { !$0.isLocked }) { object in
                        objectOverlay(object, scale: scale)
                    }
                    if let selection, editingID == nil, !slide.objects[selection].isLocked {
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func objectOverlay(_ object: SlideObject, scale: CGFloat) -> some View {
        let width = CGFloat(object.width) * scale
        let height = CGFloat(object.height) * scale
        if editingID == object.id {
            TextEditor(text: textBinding(object.id))
                .font(.system(size: object.fontSize * scale, weight: object.bold ? .bold : .regular))
                .foregroundStyle(Color(nsColor: Palette.color(object.color)))
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: Palette.color(slide.background)))
                .focused($canvasTextFocused)
                .onAppear { canvasTextFocused = true }
                .onExitCommand { editingID = nil }
                .frame(width: width, height: height)
                .overlay(Rectangle().strokeBorder(Color.accentColor, lineWidth: 2).allowsHitTesting(false))
                .position(x: object.x * scale + width / 2, y: object.y * scale + height / 2)
                .zIndex(1)
        } else {
            ObjectHitArea(object: object, selected: objectID == object.id, scale: scale,
                          slideBackground: slide.background, images: deck.images, canvas: deck.pageCanvas,
                          select: { focusCanvas(); objectID = object.id },
                          edit: {
                              focusCanvas()
                              objectID = object.id
                              if object.kind == .text { editingID = object.id }
                              if object.kind == .table { editTable = object }
                          },
                          move: { offset in
                              guard let i = slide.objects.firstIndex(where: { $0.id == object.id }) else { return }
                              var updated = slide
                              updated.objects[i].x = (object.x + offset.width / scale).clamped(-960...960)
                              updated.objects[i].y = (object.y + offset.height / scale).clamped(-540...540)
                              document.deck.slides[index] = updated
                          })
                .frame(width: width, height: height)
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
                Picker("讲解标记", selection: slideBinding(\.teachingCue)) {
                    Text("无").tag(nil as Slide.TeachingCue?)
                    ForEach(Slide.TeachingCue.allCases) { cue in Text(cue.rawValue).tag(Optional(cue)) }
                }.fixedSize()
                Spacer()
                Stepper("\(Int(notesFontSize)) 磅", value: $notesFontSize, in: 12...36)
                Button("专注视图") { notesFocus = true }
            }
            TextEditor(text: slideBinding(\.speakerNotes))
                .font(.system(size: notesFontSize))
                .scrollContentBackground(.hidden)
                .frame(height: (notesHeight + notesResize).clamped(72...260))
                .accessibilityLabel("逐字讲稿")
        }
        .padding(.horizontal, 12).padding(.bottom, 10)
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("版面属性").font(.headline)
                Button("幻灯片尺寸…") { canvasSheet = true }
                Button("学术引文与出处…") { citationSheet = true }
                Toggle("课堂书签", isOn: Binding(get: { slide.bookmarked == true },
                                                   set: { slideBinding(\.bookmarked).wrappedValue = $0 ? true : nil }))
                Toggle("备用页", isOn: Binding(get: { slide.isBackup }, set: { setBackup($0, for: [slide.id]) }))
                    .help("顺序放映时跳过，可在放映中手动调出。")
                TextField("章节名称", text: slideBinding(\.section))
                colorMenu("页背景", selection: slideBinding(\.background),
                          colors: [("米白", Palette.paper), ("纯白", "FFFFFF"), ("深蓝", Palette.ink), ("淡蓝", "EDF2FC")])
                Divider()
                if let selection {
                    let object = slide.objects[selection]
                    Text(object.label).font(.headline).lineLimit(2)
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
                        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 10) {
                            GridRow {
                                number("X", object: object, key: \.x, range: -960...960)
                                number("Y", object: object, key: \.y, range: -540...540)
                            }
                            GridRow {
                                number("宽", object: object, key: \.width, range: 1...1920)
                                number("高", object: object, key: \.height, range: 1...1080)
                            }
                        }
                        HStack {
                            Button("置顶") { changeLayer(object.id, front: true) }
                            Button("置底") { changeLayer(object.id, front: false) }
                        }
                        Button("删除对象", role: .destructive) { removeObject(object.id) }
                    }
                }
                if !slide.objects.isEmpty {
                    Divider()
                    Text("对象").font(.headline)
                    ForEach(slide.objects.reversed()) { object in
                        Button {
                            focusCanvas()
                            objectID = object.id
                        } label: {
                            Label(object.label, systemImage: object.isLocked ? "lock" : object.kind == .text ? "textformat" :
                                    object.kind == .image ? "photo" : object.kind == .table ? "tablecells" :
                                    object.kind == .connector ? "arrow.up.right" : "rectangle")
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .padding(5)
                        .background(objectID == object.id ? Color.accentColor.opacity(0.12) : .clear,
                                    in: .rect(cornerRadius: 4))
                    }
                }
            }
            .padding(14)
        }
        .background(Color(nsColor: .controlBackgroundColor))
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
                guard var updated = SlideConnector.object(from: ends.start, to: ends.end, style: line, color: current.color) else { return }
                updated.id = current.id
                document.deck.slides[index].objects[position] = updated
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
        var layout = object.textLayout ?? .init()
        let count = object.text.components(separatedBy: "\n").count
        layout.paragraphs = (0..<count).map { index in
            var style = layout.paragraphs.indices.contains(index) ? layout.paragraphs[index] : .init()
            style.alignment = alignment
            return style
        }
        object.textLayout = layout
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
        if !search.isEmpty && !filteredSlides.contains(where: { $0.id == id }) {
            search = ""
        }
        selectPages([id])
    }

    private func editorPage(_ direction: Int) -> UUID? {
        deck.editorPage(after: index, direction: direction,
                        matching: search.isEmpty ? nil : Set(filteredSlides.map(\.id)))
    }

    private func stepEditorPage(_ direction: Int) {
        if let target = editorPage(direction) { selectPages([target]) }
    }

    private func stepVisitHistory(backward: Bool) {
        guard let page = visitHistory.step(from: slide.id, backward: backward, available: Set(deck.slides.map(\.id))) else { return }
        if !search.isEmpty && !filteredSlides.contains(where: { $0.id == page }) { search = "" }
        activatePages(SidebarPageSelection(current: page, selected: [page], anchor: page),
                      reveal: true, recordVisit: false)
    }

    private func handleShortcut(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
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
                NSWorkspace.shared.activateFileViewerSelecting([result])
            } catch { linkedError = "无法导出授课资料。\n\(error.localizedDescription)" }
        }
    }

    private func exportTeachingPDF(_ format: TeachingPDF.Format) {
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
            } catch { linkedError = "无法导出 PDF。\n\(error.localizedDescription)" }
        }
    }

    private func export(_ type: ExportType) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type.contentType]
        panel.nameFieldStringValue = session.name + "." + type.rawValue
        let backupOption = type == .pdf ? backupExportOption(for: panel) : nil
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            switch type {
            case .pdf: try SlideDrawing.pdf(deck, includeBackups: backupOption?.state == .on, to: url)
            case .powerPoint: try PowerPoint.write(deck, to: url)
            }
        } catch { linkedError = error.localizedDescription }
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
    static func readForEditor(_ url: URL, progress: ((Int, Int) -> Void)? = nil) throws -> ImportedDeck {
        try read(url, fontAvailable: { SlideFonts.named($0, size: 12) != nil }, progress: progress) { data in
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

private enum ExportType: String {
    case pdf
    case powerPoint = "pptx"
    var contentType: UTType {
        switch self {
        case .pdf: .pdf
        case .powerPoint: .slidePowerPoint
        }
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
                .onEnded { drag in select(); move(drag.translation) })
            .offset(translation ?? .zero)
            .accessibilityLabel(object.label)
    }
}

private extension Double {
    func clamped(_ range: ClosedRange<Double>) -> Double {
        isFinite ? min(range.upperBound, max(range.lowerBound, self)) : range.lowerBound
    }
}
