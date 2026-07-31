import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsStore
    var onClose: () -> Void
    @FocusState private var keyFocused: Bool

    private var currentModel: ModelInfo {
        ModelInfo.info(settings.model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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

            Form {
                Section("DeepSeek API") {
                    SecureField("API Key", text: $settings.apiKey)
                        .focused($keyFocused)
                    Label(
                        settings.keyConfigured ? "已配置" : "未配置",
                        systemImage: settings.keyConfigured ? "checkmark.circle.fill" : "exclamationmark.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(settings.keyConfigured ? .green : .orange)
                    Text("Key 保存在 macOS 钥匙串中，直接请求 DeepSeek API")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("模型") {
                    Picker("模型", selection: $settings.model) {
                        ForEach(ModelInfo.all) { info in
                            Text(info.name).tag(info.id)
                        }
                    }
                    Toggle("思考模式", isOn: $settings.thinking)
                    if settings.thinking {
                        Picker("思考强度", selection: $settings.effort) {
                            ForEach(Effort.allCases) { effort in
                                Text(effort.label).tag(effort)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    Toggle("联网搜索", isOn: webSearchBinding)
                        .disabled(!currentModel.supportsResponses)
                    if !currentModel.supportsResponses {
                        Text("Responses API 暂未支持 V4 Pro，预计 2026 年 8 月初开放")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .padding(16)
        .frame(width: 420)
        .onAppear {
            // 面板显示后自动聚焦输入框，保证粘贴/输入直达
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                keyFocused = true
            }
        }
    }

    private var webSearchBinding: Binding<Bool> {
        Binding(
            get: { settings.webSearch && currentModel.supportsResponses },
            set: { settings.webSearch = $0 }
        )
    }
}
