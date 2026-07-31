import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var sessionStore: SessionStore
    var onClose: () -> Void

    @FocusState private var keyFocused: Bool
    @State private var showKey = false
    @State private var keyCheckState: KeyCheckState = .idle

    private enum KeyCheckState: Equatable {
        case idle
        case checking
        case success(modelCount: Int)
        case failure(String)
    }

    private var currentModel: ModelInfo {
        settings.modelInfo(for: settings.model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            DragHandleStrip()
            HStack {
                Button(action: onClose) {
                    Label("返回", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                Text("设置")
                    .font(.headline)
                Spacer()
            }

            ScrollView {
                Form {
                    apiSection
                    modelSection
                    providerSection
                    conversationSection
                    windowSection
                    dataSection
                }
                .formStyle(.grouped)
                // 表单限宽 420 居中；外层不再固定 420pt——
                // 固定宽度会成为内容固有宽度，把 NSPanel 拽窄且 autosave
                // 记住窄尺寸，返回主界面后窗口无法恢复原大小。
                .frame(maxWidth: 420)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(DesignTokens.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            // 面板显示后自动聚焦输入框，保证粘贴/输入直达
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                keyFocused = true
            }
        }
        .onChange(of: settings.apiKey) { _, _ in
            // Key 被修改后，旧的连接结果不再有效
            keyCheckState = .idle
        }
    }

    // MARK: - 分区

    private var apiSection: some View {
        Section("DeepSeek API") {
            HStack(spacing: 8) {
                Group {
                    if showKey {
                        TextField("API Key", text: $settings.apiKey)
                    } else {
                        SecureField("API Key", text: $settings.apiKey)
                    }
                }
                .focused($keyFocused)

                Button {
                    showKey.toggle()
                } label: {
                    Image(systemName: showKey ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(showKey ? "隐藏 API Key" : "显示 API Key")
            }

            HStack {
                Label(
                    settings.keyConfigured ? "已配置" : "未配置",
                    systemImage: settings.keyConfigured
                        ? "checkmark.circle.fill" : "exclamationmark.circle"
                )
                .font(.caption)
                .foregroundStyle(settings.keyConfigured ? .green : .orange)

                Spacer()

                Button(action: checkConnection) {
                    if keyCheckState == .checking {
                        HStack(spacing: 4) {
                            ProgressView()
                                .controlSize(.mini)
                            Text("测试中…")
                        }
                    } else {
                        Text("测试连接")
                    }
                }
                .controlSize(.small)
                .disabled(!settings.keyConfigured || keyCheckState == .checking)
            }

            keyCheckStatus

            Text("Key 保存在 macOS 钥匙串中，请求直接发往所选供应商 API")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var modelSection: some View {
        Section("模型") {
            Picker("模型", selection: $settings.model) {
                ForEach(settings.availableModels) { info in
                    Text(info.name).tag(info.id)
                }
            }
            Toggle("思考模式", isOn: $settings.thinking)
                .disabled(currentModel.isCustom)
            if settings.thinking {
                Picker("思考强度", selection: $settings.effort) {
                    ForEach(Effort.allCases) { effort in
                        Text(effort.label).tag(effort)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(currentModel.isCustom)
            }
            if currentModel.isCustom {
                Text("自定义模型暂不支持思考模式与联网搜索")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle("联网搜索", isOn: webSearchBinding)
                .disabled(!currentModel.supportsResponses)
            if !currentModel.supportsResponses {
                Text(
                    currentModel.isCustom
                        ? "自定义模型走 OpenAI 兼容 Chat Completions，不支持 Responses API"
                        : "Responses API 暂未支持 V4 Pro，预计 2026 年 8 月初开放"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var providerSection: some View {
        Section("自定义模型供应商") {
            Toggle("启用自定义供应商", isOn: $settings.customProviderEnabled)

            if settings.customProviderEnabled {
                TextField("API Base URL", text: $settings.customBaseURL)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()

                ForEach(settings.customModels.indices, id: \.self) { index in
                    HStack(spacing: 8) {
                        TextField("模型 ID（如 gpt-4o）", text: $settings.customModels[index].id)
                            .textFieldStyle(.roundedBorder)
                        TextField("显示名称", text: $settings.customModels[index].name)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            settings.customModels.remove(at: index)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                    }
                }

                Button {
                    settings.customModels.append(CustomModel(id: "", name: ""))
                } label: {
                    Label("添加模型", systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)
            }

            Text(
                "自定义供应商走 OpenAI 兼容 Chat Completions 接口（{base}/chat/completions）；思考模式与联网搜索为 DeepSeek 专属能力，自定义模型暂不支持"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var conversationSection: some View {
        Section("对话设置") {
            VStack(alignment: .leading, spacing: 4) {
                Text("System Prompt")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $settings.systemPrompt)
                    .font(.system(size: 13))
                    .frame(height: 64)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.25))
                    )
                Text("作为系统指令随每次请求发送；留空使用模型默认行为")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("自定义 temperature", isOn: temperatureEnabled)
            if customTemperature {
                HStack(spacing: 8) {
                    Text("随机性")
                    Slider(value: temperatureValue, in: 0...2, step: 0.1)
                    Text(String(format: "%.1f", settings.temperature ?? 1.0))
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 32, alignment: .trailing)
                }
                Text("数值越高回答越随机，越低越稳定；范围 0~2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var dataSection: some View {
        Section("数据") {
            HStack {
                Button("导出全部会话…") {
                    SessionFileTransfer.exportAll(from: sessionStore)
                }
                .disabled(sessionStore.sessions.isEmpty)
                Button("导入会话…") {
                    SessionFileTransfer.importInto(sessionStore)
                }
            }
            Text("导出为 JSON 备份文件，可在本应用或其他设备恢复；导入会追加新会话，不会覆盖现有数据")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var windowSection: some View {
        Section("窗口") {
            Picker("窗口大小", selection: $settings.windowSizePreset) {
                ForEach(WindowSizePreset.allCases) { preset in
                    Text(preset.label).tag(preset)
                }
            }
            Text("按主屏可见区域比例预设；选择后每次启动按所选档位生效，覆盖手动调整过的旧窗口大小")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 连接测试

    @ViewBuilder
    private var keyCheckStatus: some View {
        switch keyCheckState {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text("正在连接 DeepSeek API…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .success(let modelCount):
            Label("连接成功，可用模型 \(modelCount) 个", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failure(let message):
            Label("连接失败：\(message)", systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }

    private func checkConnection() {
        guard !settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        keyCheckState = .checking
        Task { @MainActor in
            let result = await ConnectionChecker().check(
                apiKey: settings.apiKey,
                baseURL: settings.activeBaseURL
            )
            switch result {
            case .success(let modelCount):
                keyCheckState = .success(modelCount: modelCount)
            case .failure(let error):
                keyCheckState = .failure(error.localizedDescription)
            }
        }
    }

    // MARK: - 绑定

    private var webSearchBinding: Binding<Bool> {
        Binding(
            get: { settings.webSearch && currentModel.supportsResponses },
            set: { settings.webSearch = $0 }
        )
    }

    private var temperatureEnabled: Binding<Bool> {
        Binding(
            get: { settings.temperature != nil },
            set: { enabled in
                settings.temperature = enabled ? (settings.temperature ?? 1.0) : nil
            }
        )
    }

    private var customTemperature: Bool {
        settings.temperature != nil
    }

    private var temperatureValue: Binding<Double> {
        Binding(
            get: { settings.temperature ?? 1.0 },
            set: { settings.temperature = $0 }
        )
    }
}
