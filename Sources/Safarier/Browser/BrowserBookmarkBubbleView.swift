import AppKit
import SwiftUI
import SafarierCore

/// Chrome 风格的网页书签气泡弹窗视图 (Bookmark Bubble Popover)
/// 针对当前网页提供：星标添加确认、名称/网址编辑、一键移除，并提供全部书签快速检索与直达导航。
struct BrowserBookmarkBubbleView: View {
    let workspace: SafarierWorkspace
    let profileID: UUID
    let currentURL: URL?
    let currentTitle: String
    let onNavigate: (URL) -> Void
    let onStateChanged: () -> Void
    var onOpenAllBookmarks: (() -> Void)? = nil
    let onClose: () -> Void

    @State private var title: String = ""
    @State private var urlString: String = ""
    @State private var isExistingBookmark: Bool = false
    @State private var allBookmarks: [Bookmark] = []
    @State private var searchText: String = ""
    @State private var statusMessage: String?
    @State private var snapshotRevision: UUID?

    private var store: BookmarkStore {
        BookmarkStore(workspace: workspace, profileID: profileID)
    }

    private var filteredBookmarks: [Bookmark] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return allBookmarks }
        return allBookmarks.filter {
            $0.title.localizedCaseInsensitiveContains(query) ||
            $0.url.absoluteString.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 顶部标题栏
            HStack(spacing: 8) {
                Image(systemName: "star.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.yellow)

                Text(currentURL != nil ? (isExistingBookmark ? "修改书签" : "已添加到书签") : "环境书签")
                    .font(.system(size: 13.5, weight: .bold))

                Spacer()

                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(4)
                }
                .buttonStyle(.plain)
            }

            // 当前网页书签快捷编辑区（仅当处于具体网页时展示）
            if currentURL != nil {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("名称")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)

                        TextField("书签名称", text: $title)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.black.opacity(0.25))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.8)
                                    )
                            )
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("网址")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)

                        TextField("https://…", text: $urlString)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11, design: .monospaced))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.black.opacity(0.25))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.8)
                                    )
                            )
                    }

                    HStack {
                        Button(role: .destructive) {
                            removeCurrent()
                        } label: {
                            Text("移除")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(Color.red.opacity(0.9))
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        Button {
                            saveCurrent()
                            onClose()
                        } label: {
                            Text("完成")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(MetallicTheme.darkText)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 4.5)
                                .background(
                                    Capsule()
                                        .fill(MetallicTheme.prominentGradient)
                                        .overlay(Capsule().strokeBorder(MetallicTheme.metallicRimBorder, lineWidth: 0.7))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.7)
                        )
                )

                Divider().opacity(0.2)
            }

            // 全部书签检索与列表
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("快速访问 (\(allBookmarks.count))")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.secondary)

                    Spacer()
                }

                if allBookmarks.count >= 3 {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                        TextField("搜索书签…", text: $searchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11))
                        if !searchText.isEmpty {
                            Button { searchText = "" } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4.5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.black.opacity(0.2))
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 0.6))
                    )
                }

                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(filteredBookmarks) { bookmark in
                            BubbleBookmarkRow(
                                bookmark: bookmark,
                                onSelect: {
                                    onNavigate(bookmark.url)
                                },
                                onDelete: {
                                    deleteBookmark(bookmark)
                                }
                            )
                        }

                        if filteredBookmarks.isEmpty {
                            VStack(spacing: 6) {
                                Image(systemName: "star")
                                    .font(.system(size: 18))
                                    .foregroundStyle(.tertiary)
                                Text(allBookmarks.isEmpty ? "暂无其他书签" : "未找到匹配书签")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                        }
                    }
                }
                .frame(maxHeight: 180)
            }

            if let onOpenAllBookmarks {
                Button {
                    onClose()
                    onOpenAllBookmarks()
                } label: {
                    HStack {
                        Image(systemName: "books.vertical")
                            .font(.system(size: 11))
                            .foregroundStyle(MetallicTheme.accent)
                        Text("打开完整收藏夹列表")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(MetallicTheme.accent)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(MetallicTheme.accent)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(MetallicTheme.accent.opacity(0.08))
                    )
                }
                .buttonStyle(.plain)
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
        }
        .padding(14)
        .frame(width: 320)
        .background(VisualEffectBackground(material: .popover, blendingMode: .behindWindow))
        .onAppear {
            loadInitial()
        }
    }

    // MARK: - 数据处理

    private func loadInitial() {
        do {
            let snap = try store.load()
            snapshotRevision = snap.revision
            allBookmarks = snap.items

            if let currentURL {
                let normalizedCurrent = normalize(currentURL)
                if let match = snap.items.first(where: { normalize($0.url) == normalizedCurrent }) {
                    isExistingBookmark = true
                    title = match.title
                    urlString = match.url.absoluteString
                } else {
                    // Chrome 交互规范：在未收藏页面点击星标，即刻预存加入书签并允许编辑
                    isExistingBookmark = false
                    title = currentTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (currentURL.host ?? "网页") : currentTitle
                    urlString = currentURL.absoluteString

                    let newBookmark = try Bookmark(title: title, url: currentURL)
                    let newItems = snap.items + [newBookmark]
                    let updated = try store.save(newItems, expectedRevision: snap.revision)
                    snapshotRevision = updated.revision
                    allBookmarks = updated.items
                    onStateChanged()
                }
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func saveCurrent() {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let revision = snapshotRevision else { return }
        do {
            let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (url.host ?? "网页") : title
            let item = try Bookmark(title: cleanTitle, url: url)

            let normalized = normalize(url)
            var items = allBookmarks
            if let index = items.firstIndex(where: { normalize($0.url) == normalized }) {
                items[index] = item
            } else {
                items.append(item)
            }

            let updated = try store.save(items, expectedRevision: revision)
            snapshotRevision = updated.revision
            allBookmarks = updated.items
            onStateChanged()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func removeCurrent() {
        guard let currentURL, let revision = snapshotRevision else { return }
        let normalized = normalize(currentURL)
        let filtered = allBookmarks.filter { normalize($0.url) != normalized }
        do {
            let updated = try store.save(filtered, expectedRevision: revision)
            snapshotRevision = updated.revision
            allBookmarks = updated.items
            onStateChanged()
            onClose()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func deleteBookmark(_ bookmark: Bookmark) {
        guard let revision = snapshotRevision else { return }
        let filtered = allBookmarks.filter { $0.id != bookmark.id }
        do {
            let updated = try store.save(filtered, expectedRevision: revision)
            snapshotRevision = updated.revision
            allBookmarks = updated.items
            if let currentURL, normalize(currentURL) == normalize(bookmark.url) {
                isExistingBookmark = false
            }
            onStateChanged()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func normalize(_ url: URL) -> String {
        url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

// MARK: - 书签气泡行组件

private struct BubbleBookmarkRow: View {
    let bookmark: Bookmark
    let onSelect: () -> Void
    let onDelete: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onSelect) {
                HStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                            .frame(width: 22, height: 22)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.6)
                            )
                        FaviconImageView(url: bookmark.url, size: 13)
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        Text(bookmark.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text(bookmark.url.host ?? bookmark.url.absoluteString)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isHovered {
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help("删除书签")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovered ? Color.white.opacity(0.06) : Color.clear)
        )
        .onHover { isHovered = $0 }
    }
}
