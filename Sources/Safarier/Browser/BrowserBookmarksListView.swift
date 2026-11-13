import AppKit
import SwiftUI
import SafarierCore

/// Chrome / Safari 风格的环境收藏夹列表完整视图 (Bookmarks List Popover / Panel)
/// 提供：全部书签检索、即时过滤、当前网页一键快捷收藏、点击打开、⌘点按/按钮在新标签页打开、单项删除。
struct BrowserBookmarksListView: View {
    let workspace: SafarierWorkspace
    let profile: Profile
    let currentURL: URL?
    let currentTitle: String
    let onNavigate: (URL) -> Void
    let onOpenInNewTab: (URL) -> Void
    let onOpenStarBubble: () -> Void
    let onClose: () -> Void

    @State private var allBookmarks: [Bookmark] = []
    @State private var searchText: String = ""
    @State private var snapshotRevision: UUID?
    @State private var statusMessage: String?

    private var store: BookmarkStore {
        BookmarkStore(workspace: workspace, profileID: profile.id)
    }

    private var filteredBookmarks: [Bookmark] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return allBookmarks }
        return allBookmarks.filter {
            $0.title.localizedCaseInsensitiveContains(query) ||
            $0.url.absoluteString.localizedCaseInsensitiveContains(query)
        }
    }

    private var isCurrentURLBookmarked: Bool {
        guard let currentURL else { return false }
        let norm = normalize(currentURL)
        return allBookmarks.contains { normalize($0.url) == norm }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 顶栏：标题 + 数量胶囊 + 操作按钮
            HStack(spacing: 8) {
                Image(systemName: "books.vertical.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(MetallicTheme.accent)

                Text("收藏夹")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.primary)

                Text("\(allBookmarks.count)")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(MetallicTheme.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(MetallicTheme.accent.opacity(0.12))
                            .overlay(Capsule().strokeBorder(MetallicTheme.accent.opacity(0.25), lineWidth: 0.6))
                    )

                Spacer()

                if currentURL != nil {
                    Button {
                        onOpenStarBubble()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: isCurrentURLBookmarked ? "star.fill" : "star")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(isCurrentURLBookmarked ? Color.yellow : .secondary)
                            Text(isCurrentURLBookmarked ? "已收藏" : "收藏本页")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(isCurrentURLBookmarked ? Color.yellow : .secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3.5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.white.opacity(0.06))
                                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.white.opacity(0.1), lineWidth: 0.6))
                        )
                    }
                    .buttonStyle(.plain)
                    .help(isCurrentURLBookmarked ? "修改当前网页书签" : "将当前网页添加到收藏夹")
                }

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

            // 搜索框
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)

                TextField("搜索收藏夹…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.black.opacity(0.25))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.8)
                    )
            )

            // 快捷提示条：当前网页未收藏时一键快速收藏
            if let currentURL, !isCurrentURLBookmarked, searchText.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(MetallicTheme.accent)

                    VStack(alignment: .leading, spacing: 1) {
                        Text("快速收藏当前网页")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(currentTitle.isEmpty ? (currentURL.host ?? currentURL.absoluteString) : currentTitle)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Button {
                        addCurrentPage()
                    } label: {
                        Text("添加")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(MetallicTheme.darkText)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3.5)
                            .background(
                                Capsule()
                                    .fill(MetallicTheme.prominentGradient)
                                    .overlay(Capsule().strokeBorder(MetallicTheme.metallicRimBorder, lineWidth: 0.7))
                            )
                    }
                    .buttonStyle(.plain)
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(MetallicTheme.accent.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(MetallicTheme.accent.opacity(0.2), lineWidth: 0.7)
                        )
                )
            }

            Divider().opacity(0.15)

            // 书签列表
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(filteredBookmarks) { bookmark in
                        BookmarkItemRow(
                            bookmark: bookmark,
                            onOpen: {
                                let hasCmd = NSEvent.modifierFlags.contains(.command)
                                if hasCmd {
                                    onOpenInNewTab(bookmark.url)
                                } else {
                                    onNavigate(bookmark.url)
                                }
                            },
                            onOpenInNewTab: {
                                onOpenInNewTab(bookmark.url)
                            },
                            onDelete: {
                                deleteBookmark(bookmark)
                            }
                        )
                    }

                    if filteredBookmarks.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: allBookmarks.isEmpty ? "star.slash" : "magnifyingglass")
                                .font(.system(size: 26))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 16)

                            Text(allBookmarks.isEmpty ? "暂无收藏的书签" : "未找到匹配书签")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(.secondary)

                            Text(allBookmarks.isEmpty ? "在浏览网页时，点击星标或按 ⌘D 即可加入收藏" : "尝试更换搜索关键词")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.tertiary)
                                .padding(.bottom, 16)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 280)

            // 底栏提示
            HStack {
                Text(allBookmarks.isEmpty ? "提示：按 ⌘D 快速收藏网页" : "点击直接打开 · ⌘点按在新标签页中打开")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)

                Spacer()

                if let statusMessage {
                    Text(statusMessage)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(14)
        .frame(width: 360)
        .background(VisualEffectBackground(material: .popover, blendingMode: .behindWindow))
        .onAppear {
            loadBookmarks()
        }
    }

    // MARK: - 数据读取与变更

    private func loadBookmarks() {
        do {
            let snap = try store.load()
            snapshotRevision = snap.revision
            allBookmarks = snap.items
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func addCurrentPage() {
        guard let currentURL, let revision = snapshotRevision else { return }
        do {
            let title = currentTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (currentURL.host ?? "网页") : currentTitle
            let newBookmark = try Bookmark(title: title, url: currentURL)
            let updatedItems = allBookmarks + [newBookmark]
            let updated = try store.save(updatedItems, expectedRevision: revision)
            snapshotRevision = updated.revision
            allBookmarks = updated.items
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
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func normalize(_ url: URL) -> String {
        url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

// MARK: - 单个书签项行组件

private struct BookmarkItemRow: View {
    let bookmark: Bookmark
    let onOpen: () -> Void
    let onOpenInNewTab: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onOpen) {
                HStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                            .frame(width: 26, height: 26)
                            .overlay(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.6)
                            )
                        FaviconImageView(url: bookmark.url, size: 15)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(bookmark.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text(bookmark.url.host ?? bookmark.url.absoluteString)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isHovered {
                HStack(spacing: 4) {
                    Button(action: onOpenInNewTab) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(Color.white.opacity(0.08))
                            )
                    }
                    .buttonStyle(.plain)
                    .help("在新标签页中打开")

                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Color.red.opacity(0.85))
                            .frame(width: 20, height: 20)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(Color.red.opacity(0.12))
                            )
                    }
                    .buttonStyle(.plain)
                    .help("删除书签")
                }
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isHovered ? Color.white.opacity(0.07) : Color.clear)
        )
        .onHover { isHovered = $0 }
    }
}
