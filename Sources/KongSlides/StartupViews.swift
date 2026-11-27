import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct KongSlidesStartup: View {
    let session: EditorFileSession

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.06, green: 0.12, blue: 0.26),
                                    Color(red: 0.15, green: 0.34, blue: 0.78)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 14) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)
                    .accessibilityHidden(true)
                Text("KongOffice")
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(3)
                    .foregroundStyle(.white.opacity(0.78))
                Text("KongSlides").font(.system(size: 42, weight: .semibold))
                Text("课件编辑与课堂放映")
                    .font(.headline).foregroundStyle(.white.opacity(0.8))
                if let total = session.progress.total, session.opening {
                    ProgressView(value: Double(session.progress.completed), total: Double(total)) {
                        Text("正在转换 PPTX · \(session.progress.completed) / \(total) 页")
                    }.frame(width: 240).tint(.white)
                    Button("取消打开") { session.cancelOpening() }.tint(.white)
                } else {
                    ProgressView(session.opening ? "正在读取课件…" : "正在启动")
                        .controlSize(.small).tint(.white).padding(.top, 6)
                    if session.opening { Button("取消打开") { session.cancelOpening() }.tint(.white) }
                }
            }
            .foregroundStyle(.white)
            .padding(40)
        }
        .accessibilityIdentifier("kongoffice-startup")
    }
}

struct KongSlidesHome: View {
    let session: EditorFileSession
    @State private var query = ""
    @State private var recovery = false
    @State private var selection: HomeFileSelection?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            if let path = session.homeLibrary.lastEdited, let item = session.homeLibrary.previews[path] {
                resumeCard(path: path, item: item)
            }
            if session.opening { loading }
            TextField("搜索收藏和最近打开的课件", text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("kongslides-home-search")
            HStack(alignment: .top, spacing: 18) {
                favoritesPanel
                collection("最近打开", icon: "clock", urls: session.recentURLs,
                           empty: "打开过的课件会显示在这里。")
            }
        }
        .padding(26)
        .frame(maxWidth: 1180, maxHeight: .infinity, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("kongslides-home")
        .dropDestination(for: URL.self) { urls, _ in
            guard urls.count == 1, let url = urls.first, url.isFileURL,
                  ["ppt", "pptx", "kongslides"].contains(url.pathExtension.lowercased()) else { return false }
            session.open(url)
            return true
        }
        .sheet(item: $selection) { file in
            HomeFilePreview(url: file.url, cached: session.homeLibrary.previews[HomeLibrary.path(file.url)]) {
                session.open(file.url)
            }
        }
        .sheet(isPresented: $recovery) {
            RecoveryBrowser { original, name in
                var copy = original
                copy.importedTitle = name + "（恢复）"
                return session.replace(with: copy, markEdited: true)
            }
        }
        .alert("操作未完成", isPresented: Binding(
            get: { session.error != nil }, set: { if !$0 { session.error = nil } }
        )) {
            Button("好", role: .cancel) { session.error = nil }
        } message: { Text(session.error ?? "") }
    }

    private var header: some View {
        HStack(spacing: 20) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable().frame(width: 65, height: 65).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("KongOffice")
                    .font(.caption.weight(.semibold)).tracking(2)
                    .foregroundStyle(.white.opacity(0.8))
                Text("KongSlides").font(.system(size: 34, weight: .semibold))
                if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                    Text(version).font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.8))
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                if session.hasDocument {
                    Button("继续编辑") { session.continueEditing() }
                        .tint(.white.opacity(0.16))
                }
                Button {
                    session.chooseFile()
                } label: {
                    Label("打开课件…", systemImage: "folder")
                }
                .tint(.white.opacity(0.16))
                Menu {
                    Button("空白课件") { session.newDeck() }
                    let templates = TeachingTemplate.builtIns + TeachingTemplateStore.shared.items
                    ForEach(templates) { template in
                        Button(template.name) {
                            let deck = Deck(slides: [template.slide], images: template.images, canvas: template.canvas)
                            session.replace(with: deck, markEdited: true)
                        }
                    }
                } label: {
                    Label("新建课件", systemImage: "plus.rectangle")
                }
                .tint(.white.opacity(0.16))
                Menu {
                    Button("恢复课件…") {
                        _ = RecoverySession.shared.shouldOffer()
                        recovery = true
                    }
                    if session.hasDocument {
                        Menu("当前课件的课前准备") {
                            Button("放映前检查") { session.requestHomeAction(.preflight) }
                            Button("双屏排练并计时") { session.requestHomeAction(.rehearsal) }
                            Button("导出离线授课包…") { session.requestHomeAction(.classroomPackage) }
                        }
                    }
                    Button("导出首页备份…") { backupHome() }
                    Button("导入首页备份…") { restoreHome() }
                    Button("定位缺失收藏…") {
                        if let missing = session.favoriteURLs.first(where: { !FileManager.default.fileExists(atPath: $0.path) }) {
                            locate(missing)
                        }
                    }.disabled(!session.favoriteURLs.contains { !FileManager.default.fileExists(atPath: $0.path) })
                    Button("清除最近打开") { session.clearRecent() }.disabled(session.recentURLs.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle").accessibilityLabel("更多课件操作")
                }.fixedSize()
            }
            .buttonStyle(.borderedProminent)
            .disabled(session.opening)
        }
        .foregroundStyle(.white)
        .padding(23)
        .background(
            LinearGradient(colors: [Color(red: 0.09, green: 0.17, blue: 0.36),
                                    Color(red: 0.16, green: 0.35, blue: 0.75)],
                           startPoint: .leading, endPoint: .trailing),
            in: .rect(cornerRadius: 18)
        )
    }

    private func resumeCard(path: String, item: HomeLibrary.Preview) -> some View {
        let file = URL(fileURLWithPath: path)
        return HStack(spacing: 12) {
            HomeCover(data: item.thumbnailPNG).frame(width: 104, height: 60)
            VStack(alignment: .leading, spacing: 5) {
                Text(file.deletingPathExtension().lastPathComponent).font(.headline).lineLimit(1)
                Text([item.section, "第 \(item.page) / \(item.total) 页"].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                if item.pendingRepairs > 0 || item.preflightPages != nil {
                    Text("导入待修复 \(item.pendingRepairs) 页" + (item.preflightPages.map { " · 上次检查 \($0) 页待核对" } ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if session.hasDocument {
                Menu("课前准备") {
                    Button("放映前检查") { session.requestHomeAction(.preflight) }
                    Button("双屏排练并计时") { session.requestHomeAction(.rehearsal) }
                    Button("导出离线授课包…") { session.requestHomeAction(.classroomPackage) }
                }.disabled(session.opening)
            }
            Button("接着备课") { session.open(file) }.disabled(session.opening)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 12))
    }

    private var favoritesPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("收藏", systemImage: "star").font(.headline)
                Spacer()
                Button("新建分组…", action: addGroup).controlSize(.small)
            }
            if session.favoriteURLs.isEmpty && session.homeLibrary.groups.isEmpty {
                Text("从最近打开的课件中添加收藏。")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        favorites(in: nil)
                        ForEach(session.homeLibrary.groups) { group in
                            Text(group.name).font(.subheadline.weight(.semibold)).padding(.top, 7)
                                .dropDestination(for: String.self) { values, _ in
                                    guard let path = values.first, session.homeLibrary.favorites.contains(where: { $0.path == path })
                                    else { return false }
                                    session.updateLibrary { library in
                                        if let item = library.favorites.firstIndex(where: { $0.path == path }) {
                                            library.favorites[item].group = group.id
                                        }
                                    }
                                    return true
                                }
                            favorites(in: group.id)
                        }
                    }
                }
            }
        }.padding(16)
         .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
         .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 12))
         .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.secondary.opacity(0.18)))
    }

    private func favorites(in group: UUID?) -> some View {
        ForEach(session.homeLibrary.favorites.filter { $0.group == group && matches($0.url) }) { item in
            fileRow(item.url, inFavorites: true)
                .draggable(item.path)
                .dropDestination(for: String.self) { values, _ in
                    guard let path = values.first, session.homeLibrary.favorites.contains(where: { $0.path == path })
                    else { return false }
                    session.updateLibrary { $0.move(path, before: item.path) }
                    return true
                }
            Divider()
        }
    }

    private func matches(_ url: URL) -> Bool {
        query.isEmpty || url.lastPathComponent.localizedCaseInsensitiveContains(query)
    }

    private func addGroup() {
        let alert = NSAlert()
        alert.messageText = "新建收藏分组"
        let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 245, height: 25))
        field.placeholderString = "课程名称"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "创建")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = String(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !name.isEmpty, !session.homeLibrary.groups.contains(where: { $0.name == name }) else { return }
        session.updateLibrary { $0.groups.append(.init(name: name)) }
    }

    private func locate(_ old: URL) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.kongSlides, .slidePowerPoint] + [UTType(filenameExtension: "ppt")].compactMap { $0 }
        panel.message = "请定位「" + old.lastPathComponent + "」的新位置。"
        panel.prompt = "更新位置"
        guard panel.runModal() == .OK, let new = panel.url else { return }
        session.updateLibrary { $0.relocate(HomeLibrary.path(old), to: new) }
    }

    private func backupHome() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "KongSlides-首页备份.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try JSONEncoder().encode(session.homeLibrary.portableBackup()).write(to: url, options: .atomic)
        } catch { session.error = error.localizedDescription }
    }

    private func restoreHome() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.prompt = "导入"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let info = try url.resourceValues(forKeys: [.fileSizeKey])
            guard let size = info.fileSize, size <= 8 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
            let backup = try JSONDecoder().decode(HomeLibrary.self, from: Data(contentsOf: url))
            session.updateLibrary { $0.merge(backup.portableBackup()) }
        } catch { session.error = "无法导入首页备份。\n" + error.localizedDescription }
    }

    private var loading: some View {
        HStack {
            if let total = session.progress.total, total > 0 {
                ProgressView(value: Double(session.progress.completed), total: Double(total))
                Text("\(session.progress.completed) / \(total) 页").monospacedDigit()
            } else {
                ProgressView().controlSize(.small)
                Text("正在打开课件…")
            }
            Spacer()
            Button("取消") { session.cancelOpening() }
        }
    }

    private func collection(_ title: String, icon: String, urls: [URL], empty: String) -> some View {
        let visible = urls.filter(matches)
        return VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.headline)
            if visible.isEmpty {
                Text(query.isEmpty ? empty : "没有匹配的课件。")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visible, id: \.self) { url in
                            fileRow(url)
                            Divider()
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.secondary.opacity(0.18)))
    }

    private func fileRow(_ url: URL, inFavorites: Bool = false) -> some View {
        let favorite = session.isFavorite(url)
        let name = url.deletingPathExtension().lastPathComponent
        let missing = !FileManager.default.fileExists(atPath: url.path)
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return HStack(spacing: 10) {
            Button {
                if missing && inFavorites { locate(url) }
                else { selection = HomeFileSelection(url: url) }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "doc.richtext")
                        .font(.title3).foregroundStyle(Color.accentColor).frame(width: 29)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                        let details = [url.pathExtension.uppercased(), url.deletingLastPathComponent().path,
                                       modified?.formatted(date: .abbreviated, time: .shortened),
                                       missing ? "文件位置已变" : nil].compactMap { $0 }.joined(separator: " · ")
                        Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(session.opening)
            .help(url.path)
            Button {
                session.toggleFavorite(url)
            } label: {
                Image(systemName: favorite ? "star.fill" : "star")
                    .foregroundStyle(favorite ? Color.orange : Color.secondary)
                    .frame(width: 22)
            }
            .buttonStyle(.borderless)
            .help(favorite ? "移除收藏" : "添加收藏")
            .accessibilityLabel((favorite ? "移除收藏 " : "收藏 ") + name)
        }
        .contextMenu {
            Button("打开课件") { session.open(url) }.disabled(missing)
            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.disabled(missing)
            if !inFavorites { Button("从最近记录移除") { session.removeRecent(url) } }
            if inFavorites {
                Button("重新定位…") { locate(url) }
                Menu("移到分组") {
                    Button("未分组") { setGroup(nil, for: url) }
                    ForEach(session.homeLibrary.groups) { group in
                        Button(group.name) { setGroup(group.id, for: url) }
                    }
                }
            }
            Button(favorite ? "移除收藏" : "添加收藏") { session.toggleFavorite(url) }
        }
    }

    private func setGroup(_ group: UUID?, for url: URL) {
        session.updateLibrary { value in
            if let index = value.favorites.firstIndex(where: { $0.path == HomeLibrary.path(url) }) {
                value.favorites[index].group = group
            }
        }
    }

}
