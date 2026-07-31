import AppKit
import UniformTypeIdentifiers

/// 会话导入 / 导出的文件面板与结果提示。
///
/// 复用系统 NSSavePanel / NSOpenPanel 与 NSAlert，不自己画文件对话框。
enum SessionFileTransfer {
    /// 导出全部会话（设置页）。
    static func exportAll(from store: SessionStore) {
        let panel = makeSavePanel(name: "DeepSeekChat-会话备份-\(dateStamp()).json")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try store.exportJSON()
            try data.write(to: url, options: .atomic)
            showNotice(
                title: "导出成功",
                message: "已导出 \(store.sessions.count) 个会话"
            )
        } catch {
            showNotice(title: "导出失败", message: error.localizedDescription, isError: true)
        }
    }

    /// 导出单个会话（侧边栏右键菜单）。
    static func exportSession(_ session: ChatSession, from store: SessionStore) {
        let panel = makeSavePanel(name: "\(safeFileName(session.title))-\(dateStamp()).json")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard let data = try store.exportSessionJSON(id: session.id) else {
                showNotice(title: "导出失败", message: "会话不存在", isError: true)
                return
            }
            try data.write(to: url, options: .atomic)
            showNotice(title: "导出成功", message: "已导出 1 个会话")
        } catch {
            showNotice(title: "导出失败", message: error.localizedDescription, isError: true)
        }
    }

    /// 从 JSON 备份导入会话（设置页）。
    static func importInto(_ store: SessionStore) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let result = try store.importJSON(data)
            showNotice(
                title: "导入成功",
                message: "新增 \(result.importedSessions) 个会话、\(result.importedMessages) 条消息"
            )
        } catch {
            showNotice(title: "导入失败", message: error.localizedDescription, isError: true)
        }
    }

    // MARK: - 私有辅助

    private static func makeSavePanel(name: String) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = name
        return panel
    }

    private static func dateStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    /// 会话标题可能含 `/` 等文件系统非法字符，导出文件名只保留安全部分。
    private static func safeFileName(_ title: String) -> String {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined()
        return cleaned.isEmpty ? "会话" : cleaned
    }

    private static func showNotice(title: String, message: String, isError: Bool = false) {
        let alert = NSAlert()
        alert.alertStyle = isError ? .warning : .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}
