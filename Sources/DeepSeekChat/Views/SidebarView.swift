import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var sessionStore: SessionStore
    @EnvironmentObject var settings: SettingsStore

    @Binding var selectedID: UUID?
    @Binding var showSettings: Bool

    /// 正在行内重命名的会话 ID（nil = 无）。
    @State private var renamingID: UUID?
    @State private var renameDraft = ""

    private var sortedSessions: [ChatSession] {
        sessionStore.sessions.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// 分组：置顶组在最前，其余按「今天 / 昨天 / 更早」，组内按 updatedAt 倒序。
    private var groupedSessions: [SessionGroup] {
        let pinned = sortedSessions.filter(\.isPinned)
        let unpinned = sortedSessions.filter { !$0.isPinned }
        let buckets = Dictionary(grouping: unpinned) { session -> String in
            let calendar = Calendar.current
            if calendar.isDateInToday(session.updatedAt) { return "今天" }
            if calendar.isDateInYesterday(session.updatedAt) { return "昨天" }
            return "更早"
        }
        return [
            SessionGroup(title: "置顶", sessions: pinned),
            SessionGroup(title: "今天", sessions: buckets["今天"] ?? []),
            SessionGroup(title: "昨天", sessions: buckets["昨天"] ?? []),
            SessionGroup(title: "更早", sessions: buckets["更早"] ?? []),
        ]
        .filter { !$0.sessions.isEmpty }
    }

    private var currentModel: ModelInfo {
        settings.modelInfo(for: settings.model)
    }

    var body: some View {
        VStack(spacing: 0) {
            DragHandleStrip()

            Button(action: newChat) {
                Label("新建对话", systemImage: "square.and.pencil")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.bottom, 8)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(groupedSessions) { group in
                        Text(group.title)
                            .font(.system(size: DesignTokens.FontSize.caption, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
                            .padding(.bottom, 2)
                        ForEach(group.sessions) { session in
                            sessionRow(session)
                        }
                    }
                }
                .padding(.horizontal, 8)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Picker("模型", selection: $settings.model) {
                    ForEach(settings.availableModels) { info in
                        Text(info.name).tag(info.id)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)

                Toggle("思考模式", isOn: $settings.thinking)
                    .controlSize(.small)
                    .disabled(currentModel.isCustom)

                if settings.thinking {
                    Picker("强度", selection: $settings.effort) {
                        ForEach(Effort.allCases) { effort in
                            Text(effort.label).tag(effort)
                        }
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.mini)
                    .disabled(currentModel.isCustom)
                }

                Toggle("联网搜索", isOn: webSearchBinding)
                    .controlSize(.small)
                    .disabled(!currentModel.supportsResponses)

                if !currentModel.supportsResponses {
                    Text(
                        currentModel.isCustom
                            ? "自定义模型暂不支持"
                            : "仅 V4 Flash 支持，V4 Pro 预计 8 月初开放"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                Button(action: { showSettings = true }) {
                    Label(
                        settings.keyConfigured ? "设置" : "设置 API Key",
                        systemImage: "key"
                    )
                    .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
            }
            .padding(10)
        }
    }

    private var webSearchBinding: Binding<Bool> {
        Binding(
            get: { settings.webSearch && currentModel.supportsResponses },
            set: { settings.webSearch = $0 }
        )
    }

    private func newChat() {
        let session = sessionStore.createSession()
        selectedID = session.id
    }

    private func sessionRow(_ session: ChatSession) -> some View {
        SidebarSessionRow(
            session: session,
            isSelected: selectedID == session.id,
            isRenaming: renamingID == session.id,
            renameDraft: $renameDraft,
            onSelect: { selectedID = session.id },
            onTogglePin: {
                sessionStore.setPinned(id: session.id, pinned: !session.isPinned)
            },
            onRename: {
                renamingID = session.id
                renameDraft = session.title
            },
            onRenameConfirm: confirmRename,
            onRenameCancel: { renamingID = nil },
            onDelete: { deleteSession(session) }
        )
        .contextMenu {
            Button(session.isPinned ? "取消置顶" : "置顶") {
                sessionStore.setPinned(id: session.id, pinned: !session.isPinned)
            }
            Button("重命名") {
                renamingID = session.id
                renameDraft = session.title
            }
            Button("导出为 JSON…") {
                SessionFileTransfer.exportSession(session, from: sessionStore)
            }
            Button("删除", role: .destructive) {
                deleteSession(session)
            }
        }
    }

    private func confirmRename() {
        guard let id = renamingID else { return }
        sessionStore.renameSession(id: id, title: renameDraft)
        renamingID = nil
    }

    private func deleteSession(_ session: ChatSession) {
        sessionStore.deleteSession(id: session.id)
        if selectedID == session.id {
            selectedID = sessionStore.sessions.first?.id
        }
    }

    private struct SessionGroup: Identifiable {
        let title: String
        let sessions: [ChatSession]
        var id: String { title }
    }
}

/// 侧栏会话行：标题 / 信息（日期 · 条数、tokens 独立子行）与快捷操作。
///
/// 独立成结构体（而非 SidebarView 私有函数）是为了让布局回归测试可以直接
/// 渲染，验证文字与快捷按钮不重叠；行自身维护 hover 状态。
struct SidebarSessionRow: View {
    let session: ChatSession
    let isSelected: Bool
    /// 是否处于行内重命名状态（标题变成输入框）。
    var isRenaming: Bool = false
    /// 行内重命名草稿。
    var renameDraft: Binding<String> = .constant("")
    let onSelect: () -> Void
    let onTogglePin: () -> Void
    let onRename: () -> Void
    let onRenameConfirm: () -> Void
    let onRenameCancel: () -> Void
    let onDelete: () -> Void

    /// 行自身维护 hover 状态，不共享 SidebarView 的 hoveredSessionID：
    /// 鼠标跨行移动时 leave/enter 顺序不定，共享 ID 会被后到的 nil 覆盖，
    /// 导致按钮闪现消失、点击落空（「取消置顶有时不起作用」）。
    @State private var isHovered = false
    @FocusState private var renameFocused: Bool

    /// 选中行常显快捷按钮（无需悬停即可置顶 / 重命名 / 删除），
    /// 其他行 hover 时显示——保证操作可发现、可点击。
    /// （internal 便于单测锁定该 UX 规则。）
    var showsQuickActions: Bool {
        isHovered || isSelected
    }

    var body: some View {
        // 行内容与快捷按钮「并排」而非 ZStack 重叠：
        // macOS 上整行 Button 与叠在其上的快捷 Button 重叠时，点击会被下层
        // 行 Button 吃掉（「点击没反应」）；并排布局天然没有命中冲突。
        HStack(spacing: 0) {
            rowContainer
            trailingActions
        }
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(rowBackground)
        )
        .onHover { hovering in
            isHovered = hovering
        }
        .onChange(of: isRenaming) { _, renaming in
            if renaming {
                renameFocused = true
            }
        }
    }

    /// 右侧操作区：重命名时「确定 / 取消」，否则快捷操作（置顶 / 重命名 / 删除）。
    /// 与行内容并排，不与行 Button 重叠。
    @ViewBuilder
    private var trailingActions: some View {
        if isRenaming {
            HStack(spacing: DesignTokens.Sidebar.quickActionSpacing) {
                quickActionButton(
                    systemImage: "checkmark",
                    help: "确定",
                    action: onRenameConfirm
                )
                quickActionButton(
                    systemImage: "xmark",
                    help: "取消",
                    action: onRenameCancel
                )
            }
            .padding(.trailing, DesignTokens.Sidebar.quickActionsTrailingPadding)
        } else if showsQuickActions {
            HStack(spacing: DesignTokens.Sidebar.quickActionSpacing) {
                quickActionButton(
                    systemImage: session.isPinned ? "pin.fill" : "pin",
                    help: session.isPinned ? "取消置顶" : "置顶",
                    foreground: session.isPinned ? Color.accentColor : Color.secondary,
                    action: onTogglePin
                )
                quickActionButton(
                    systemImage: "pencil",
                    help: "重命名",
                    action: onRename
                )
                quickActionButton(
                    systemImage: "trash",
                    help: "删除",
                    destructive: true,
                    action: onDelete
                )
            }
            .padding(.trailing, DesignTokens.Sidebar.quickActionsTrailingPadding)
        }
    }

    @ViewBuilder
    private var rowContainer: some View {
        if isRenaming {
            // 重命名时不用 Button 包裹：TextField 需要接收点击，不能被外层按钮拦截。
            rowBody
        } else {
            Button(action: onSelect) {
                rowBody
            }
            .buttonStyle(.plain)
        }
    }

    private var rowBody: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                titleSlot
                HStack(spacing: 6) {
                    Text(relativeDate)
                    Text("\(session.messages.count) 条")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                // tokens 独立子行：不再与日期 / 条数挤在同一行，
                // 也避免 hover 时被快捷按钮截断。
                if let totalTokens = totalTokens {
                    HStack(spacing: 4) {
                        Image(systemName: "chart.bar")
                            .font(.system(size: 9))
                        Text("\(TokenUsage.compact(totalTokens)) tokens")
                    }
                    .font(.system(size: DesignTokens.FontSize.caption - 1))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var titleSlot: some View {
        if isRenaming {
            TextField("会话标题", text: renameDraft)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .focused($renameFocused)
                .onSubmit { onRenameConfirm() }
                .onExitCommand { onRenameCancel() }
        } else {
            Text(session.title.isEmpty ? "新对话" : session.title)
                .font(.callout)
                .lineLimit(1)
        }
    }

    private var rowBackground: Color {
        if isSelected {
            return Color.accentColor.opacity(0.16)
        }
        if isHovered {
            return Color.secondary.opacity(0.08)
        }
        return Color.clear
    }

    /// 最近一条消息带参考来源（联网搜索过）的会话用地球图标区分。
    private var icon: String {
        if session.messages.last?.sources?.isEmpty == false {
            return "globe"
        }
        return "bubble.left"
    }

    private var totalTokens: Int? {
        let total = session.messages.reduce(0) { $0 + ($1.usage?.totalTokens ?? 0) }
        return total > 0 ? total : nil
    }

    private var relativeDate: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(session.updatedAt) { return "今天" }
        if calendar.isDateInYesterday(session.updatedAt) { return "昨天" }
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        return formatter.string(from: session.updatedAt)
    }

    private func quickActionButton(
        systemImage: String,
        help: String,
        foreground: Color = .secondary,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .frame(
                    width: DesignTokens.Sidebar.quickActionButtonSize,
                    height: DesignTokens.Sidebar.quickActionButtonSize
                )
        }
        // borderless：与窗口内其他图标按钮同款样式，避免 plain 样式在部分
        // macOS 版本下点击无响应。
        .buttonStyle(.borderless)
        .foregroundStyle(destructive ? Color.red : foreground)
        .help(help)
    }
}
