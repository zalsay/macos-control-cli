import SwiftUI
import Combine
import SafarierCore

/// Chrome 风格的环境书签与收藏管理器 (Liquid Glass Bookmark Manager)
/// 支持：书签检索、Favicon/域名胶囊展示、独立抽屉编辑与添加、一键复制网址、直达浏览器打开。
struct BookmarkManagerView: View {
    let workspace: SafarierWorkspace
    let profile: Profile
    var onOpenURL: ((URL) -> Void)? = nil

    @State private var snapshot: BookmarkStore.Snapshot?
    @State private var editing: UUID?
    @State private var isAdding = false
    @State private var title = ""
    @State private var address = ""
    @State private var searchText = ""
    @State private var message: String?
    @State private var externalChange = false
    @State private var copiedItemID: UUID?

    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    private var store: BookmarkStore { BookmarkStore(workspace: workspace, profileID: profile.id) }
    private var hasDraft: Bool { editing != nil || isAdding || !title.isEmpty || !address.isEmpty }

    private var filteredItems: [Bookmark] {
        guard let snapshot else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return snapshot.items }
        return snapshot.items.filter {
            $0.title.localizedCaseInsensitiveContains(query) ||
            $0.url.absoluteString.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        LiquidGlassCard(
            title: "环境书签",
            systemImage: "star.fill",
            badge: snapshot != nil ? "\(snapshot!.items.count)" : nil
        ) {
            VStack(alignment: .leading, spacing: 14) {
                // 卡片副标题与快捷添加按钮
                HStack(alignment: .center) {
                    Text(profile.mode == .ephemeral ? "书签随环境配置保留 · 临时环境数据在关闭后清除" : "环境专属书签 · 与浏览器地址栏星标实时双向同步")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)

                    Spacer()

                    if !isAdding && editing == nil {
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                clearDraft()
                                isAdding = true
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "plus")
                                    .font(.system(size: 11, weight: .bold))
                                Text("添加书签")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundStyle(MetallicTheme.darkText)
                            .padding(.horizontal, 10)
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

                // 搜索栏 (书签大于 2 个时展现)
                if let snapshot, snapshot.items.count >= 2 && !isAdding && editing == nil {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.tertiary)
                        TextField("搜索书签名称或网址…", text: $searchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                        if !searchText.isEmpty {
                            Button { searchText = "" } label: {
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
                            .fill(Color.black.opacity(0.18))
                            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Color.white.opacity(0.09), lineWidth: 0.6))
                    )
                }

                // 折叠抽屉：添加或编辑书签
                if isAdding || editing != nil {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(editing != nil ? "编辑书签信息" : "添加新书签")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(MetallicTheme.accent)
                            Spacer()
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("书签名称")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)

                            TextField("例如 GitHub 或 常用工作台", text: $title)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12.5))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(Color.black.opacity(0.25))
                                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 0.8))
                                )
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("网址 (URL)")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)

                            TextField("https://…", text: $address)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12, design: .monospaced))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(Color.black.opacity(0.25))
                                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 0.8))
                                )
                        }

                        HStack(spacing: 10) {
                            LiquidGlassButton(
                                title: editing != nil ? "保存修改" : "确认添加",
                                systemImage: "checkmark",
                                variant: .prominent,
                                size: .small
                            ) {
                                save()
                            }

                            LiquidGlassButton(
                                title: "取消",
                                systemImage: "xmark",
                                variant: .regular,
                                size: .small
                            ) {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    clearDraft()
                                    refresh(force: true)
                                }
                            }

                            Spacer()
                        }
                        .padding(.top, 4)
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(0.04))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(MetallicTheme.metallicRimBorder, lineWidth: 0.8)
                            )
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                // 书签列表
                if let snapshot {
                    if snapshot.items.isEmpty && !isAdding {
                        VStack(spacing: 8) {
                            ZStack {
                                Circle()
                                    .fill(Color.white.opacity(0.05))
                                    .frame(width: 44, height: 44)
                                    .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 0.8))
                                Image(systemName: "star")
                                    .font(.system(size: 20))
                                    .foregroundStyle(.tertiary)
                            }

                            Text("暂无收藏书签")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.secondary)

                            Text("在浏览器中点击星标一键收藏，或点击右上角「+ 添加书签」")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    } else {
                        VStack(spacing: 6) {
                            ForEach(filteredItems) { item in
                                bookmarkRow(item)
                            }

                            if filteredItems.isEmpty && !snapshot.items.isEmpty {
                                Text("未匹配到书签")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .padding(.vertical, 14)
                            }
                        }
                    }
                }

                if externalChange {
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                        Text("书签已在浏览器或其他窗口更改")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("同步最新") { refresh(force: true) }
                            .font(.caption.weight(.semibold))
                    }
                    .padding(.top, 4)
                }

                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.top, 2)
                }
            }
        }
        .onAppear { refresh(force: true) }
        .onReceive(timer) { _ in refresh(force: false) }
    }

    // MARK: - 书签单行视图 (Chrome 风格)

    private func bookmarkRow(_ item: Bookmark) -> some View {
        let isCopied = copiedItemID == item.id
        return HStack(spacing: 12) {
            // 网站图标 / 域名首字母徽标
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 34, height: 34)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.8)
                    )

                FaviconImageView(url: item.url, size: 18)
            }

            // 标题与域名
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(verbatim: "\(item.url.host ?? "") · \(item.url.absoluteString)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // 快捷操作按钮组
            HStack(spacing: 8) {
                // 1. 在浏览器中打开
                if let onOpenURL {
                    Button {
                        onOpenURL(item.url)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(Color.white.opacity(0.05)))
                    }
                    .buttonStyle(.plain)
                    .help("在环境中打开")
                }

                // 2. 复制链接
                Button {
                    copyToClipboard(item)
                } label: {
                    if isCopied {
                        HStack(spacing: 3) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                            Text("已复制")
                                .font(.system(size: 10.5, weight: .medium))
                        }
                        .foregroundStyle(.green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3.5)
                        .background(Capsule().fill(Color.green.opacity(0.12)))
                    } else {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(Color.white.opacity(0.05)))
                    }
                }
                .buttonStyle(.plain)
                .help("复制网址链接")

                // 3. 编辑
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        editing = item.id
                        title = item.title
                        address = item.url.absoluteString
                        isAdding = false
                    }
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.white.opacity(0.05)))
                }
                .buttonStyle(.plain)
                .help("编辑书签")

                // 4. 删除
                Button(role: .destructive) {
                    remove(item)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.red.opacity(0.75))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.white.opacity(0.05)))
                }
                .buttonStyle(.plain)
                .help("删除书签")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.6)
                )
        )
    }

    // MARK: - 操作逻辑

    private func copyToClipboard(_ item: Bookmark) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.url.absoluteString, forType: .string)
        withAnimation {
            copiedItemID = item.id
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if copiedItemID == item.id {
                withAnimation { copiedItemID = nil }
            }
        }
    }

    private func clearDraft() {
        editing = nil
        isAdding = false
        title = ""
        address = ""
        message = nil
    }

    private func refresh(force: Bool) {
        do {
            let latest = try store.load()
            if !force, hasDraft, let snapshot, snapshot.revision != latest.revision {
                externalChange = true
                message = "书签已在其他窗口更改；请检查后保存。"
                return
            }
            snapshot = latest
            externalChange = false
            if force { message = nil }
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? "无法读取书签。"
        }
    }

    private func save() {
        guard let snapshot, let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            message = "请输入有效网址 (需包含 http:// 或 https://)。"
            return
        }
        do {
            let item = try Bookmark(id: editing ?? UUID(), title: title.trimmingCharacters(in: .whitespacesAndNewlines), url: url)
            var items = snapshot.items
            if let editing {
                guard let index = items.firstIndex(where: { $0.id == editing }) else {
                    message = "书签已删除，请取消编辑。"
                    return
                }
                items[index] = item
            } else {
                items.append(item)
            }
            self.snapshot = try store.save(items, expectedRevision: snapshot.revision)
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                clearDraft()
            }
            externalChange = false
            message = nil
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? "保存失败。"
            externalChange = true
        }
    }

    private func remove(_ item: Bookmark) {
        guard let snapshot else { return }
        do {
            self.snapshot = try store.save(snapshot.items.filter { $0.id != item.id }, expectedRevision: snapshot.revision)
            if editing == item.id { clearDraft() }
            externalChange = false
            message = nil
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? "删除失败。"
            externalChange = true
        }
    }
}
