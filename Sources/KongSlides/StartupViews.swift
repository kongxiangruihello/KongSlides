import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct KongSlidesStartup: View {
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
                ProgressView().controlSize(.small).tint(.white).padding(.top, 6)
                    .accessibilityLabel("正在启动 KongSlides")
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

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            if session.opening { loading }
            TextField("搜索收藏和最近打开的课件", text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("kongslides-home-search")
            HStack(alignment: .top, spacing: 18) {
                collection("收藏", icon: "star", urls: session.favoriteURLs,
                           empty: "从最近打开的课件中添加收藏。")
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
                Button {
                    session.newDeck()
                } label: {
                    Label("新建课件", systemImage: "plus.rectangle")
                }
                .tint(.white)
                .foregroundStyle(Color(red: 0.12, green: 0.25, blue: 0.57))
                Menu {
                    Button("恢复课件…") {
                        _ = RecoverySession.shared.shouldOffer()
                        recovery = true
                    }
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
        let visible = urls.filter {
            query.isEmpty || $0.lastPathComponent.localizedCaseInsensitiveContains(query)
        }
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

    private func fileRow(_ url: URL) -> some View {
        let favorite = session.isFavorite(url)
        let name = url.deletingPathExtension().lastPathComponent
        return HStack(spacing: 10) {
            Button {
                session.open(url)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "doc.richtext")
                        .font(.title3).foregroundStyle(Color.accentColor).frame(width: 29)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                        Text(url.pathExtension.uppercased() + " · " + url.deletingLastPathComponent().lastPathComponent)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button(favorite ? "移除收藏" : "添加收藏") { session.toggleFavorite(url) }
        }
    }
}
