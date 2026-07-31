import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var sessionStore: SessionStore
    @EnvironmentObject var settings: SettingsStore

    @Binding var selectedID: UUID?
    @Binding var showSettings: Bool

    @State private var showRenameAlert = false
    @State private var renameTargetID: UUID?
    @State private var renameDraft = ""

    private var sortedSessions: [ChatSession] {
        sessionStore.sessions.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// 按「今天 / 昨天 / 更早」分组，保持组内按 updatedAt 倒序。
    private var groupedSessions: [SessionGroup] {
        let buckets = Dictionary(grouping: sortedSessions) { session -> String in
            let calendar = Calendar.current
            if calendar.isDateInToday(session.updatedAt) { return "今天" }
            if calendar.isDateInYesterday(session.updatedAt) { return "昨天" }
            return "更早"
        }
        return [
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
        .alert("重命名会话", isPresented: $showRenameAlert) {
            TextField("标题", text: $renameDraft)
            Button("确定") {
                if let id = renameTargetID {
                    sessionStore.renameSession(id: id, title: renameDraft)
                }
            }
            Button("取消", role: .cancel) {}
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
        Button {
            selectedID = session.id
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(session.title.isEmpty ? "新对话" : session.title)
                    .font(.callout)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(relativeDate(session.updatedAt))
                    Text("\(session.messages.count) 条")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(selectedID == session.id ? Color.accentColor.opacity(0.16) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("重命名") {
                renameTargetID = session.id
                renameDraft = session.title
                showRenameAlert = true
            }
            Button("导出为 JSON…") {
                SessionFileTransfer.exportSession(session, from: sessionStore)
            }
            Button("删除", role: .destructive) {
                sessionStore.deleteSession(id: session.id)
                if selectedID == session.id {
                    selectedID = sessionStore.sessions.first?.id
                }
            }
        }
    }

    private func relativeDate(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "今天" }
        if calendar.isDateInYesterday(date) { return "昨天" }
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        return formatter.string(from: date)
    }

    private struct SessionGroup: Identifiable {
        let title: String
        let sessions: [ChatSession]
        var id: String { title }
    }
}
