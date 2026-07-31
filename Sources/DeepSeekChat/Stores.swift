import Combine
import Foundation
import Security

final class SessionStore: ObservableObject {
    @Published var sessions: [ChatSession] = []

    private let directory: URL
    private let fileURL: URL
    private let saveDelay: Duration
    private var saveTask: Task<Void, Never>?

    init(
        storageDirectory: URL? = nil,
        saveDelay: Duration = .milliseconds(600)
    ) {
        let dir = storageDirectory ?? SessionStore.defaultDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        directory = dir
        fileURL = dir.appendingPathComponent("sessions.json")
        self.saveDelay = saveDelay
        load()
    }

    private static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("com.deepseek.chat", isDirectory: true)
    }

    private func load() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([ChatSession].self, from: data) {
            sessions = decoded
        } else if let migrated = Migration.migrateSessions(from: directory.appendingPathComponent("state.json")) {
            sessions = migrated
            save()
        }
    }

    // MARK: - 会话操作

    func createSession(title: String = "新对话") -> ChatSession {
        let now = Date()
        let session = ChatSession(
            id: UUID(),
            title: title,
            messages: [],
            createdAt: now,
            updatedAt: now
        )
        sessions.insert(session, at: 0)
        scheduleSave()
        return session
    }

    func deleteSession(id: UUID) {
        sessions.removeAll { $0.id == id }
        scheduleSave()
    }

    func renameSession(id: UUID, title: String) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].title = title
        objectWillChange.send()
        scheduleSave()
    }

    func session(id: UUID) -> ChatSession? {
        sessions.first { $0.id == id }
    }

    func history(for id: UUID) -> [APIMessage] {
        guard let session = session(id: id) else { return [] }
        return session.messages
            .filter { !$0.content.isEmpty }
            .map { APIMessage(role: $0.role.rawValue, content: $0.content) }
    }

    func appendMessage(sessionID: UUID, _ message: ChatMessage) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].messages.append(message)
        sessions[index].updatedAt = Date()
        objectWillChange.send()
        scheduleSave()
    }

    func updateMessage(sessionID: UUID, messageID: UUID, _ mutate: (inout ChatMessage) -> Void) {
        guard
            let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }),
            let messageIndex = sessions[sessionIndex].messages.firstIndex(where: { $0.id == messageID })
        else { return }
        mutate(&sessions[sessionIndex].messages[messageIndex])
        sessions[sessionIndex].updatedAt = Date()
        objectWillChange.send()
        scheduleSave()
    }

    // MARK: - 持久化

    private func scheduleSave() {
        if saveDelay == .zero {
            save()
            return
        }
        saveTask?.cancel()
        let delay = saveDelay
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.save()
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(sessions)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("保存会话失败: \(error)")
        }
    }
}

final class SettingsStore: ObservableObject {
    @Published var model: String {
        didSet { defaults.set(model, forKey: "model") }
    }
    @Published var thinking: Bool {
        didSet { defaults.set(thinking, forKey: "thinking") }
    }
    @Published var effort: Effort {
        didSet { defaults.set(effort.rawValue, forKey: "effort") }
    }
    @Published var webSearch: Bool {
        didSet { defaults.set(webSearch, forKey: "webSearch") }
    }
    @Published var apiKey: String {
        didSet {
            if keychainSaveDelay == .zero {
                persistKey(value: apiKey)
            } else {
                keychainSaveTask?.cancel()
                let value = apiKey
                let delay = keychainSaveDelay
                // Keychain 写入可能阻塞，防抖后在后台线程执行
                keychainSaveTask = Task.detached(priority: .utility) { [weak self] in
                    try? await Task.sleep(for: delay)
                    guard !Task.isCancelled, let self else { return }
                    self.persistKey(value: value)
                }
            }
        }
    }

    private let defaults: UserDefaults
    private let keychain: KeychainStoring
    private let keychainSaveDelay: Duration
    private var keychainSaveTask: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        keychain: KeychainStoring = KeychainStore.shared,
        keychainSaveDelay: Duration = .milliseconds(600)
    ) {
        self.defaults = defaults
        self.keychain = keychain
        self.keychainSaveDelay = keychainSaveDelay
        let savedModel = defaults.string(forKey: "model") ?? "deepseek-v4-flash"
        model =
            savedModel == "deepseek-chat" || savedModel == "deepseek-reasoner"
            ? "deepseek-v4-flash"
            : savedModel
        thinking = defaults.object(forKey: "thinking") as? Bool ?? true
        effort = Effort(rawValue: defaults.string(forKey: "effort") ?? "") ?? .high
        webSearch = defaults.bool(forKey: "webSearch")
        apiKey = keychain.read(account: "apiKey") ?? ""
    }

    var keyConfigured: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func persistKey(value: String) {
        if value.isEmpty {
            keychain.delete(account: "apiKey")
        } else {
            keychain.write(account: "apiKey", value: value)
        }
    }
}

protocol KeychainStoring {
    func read(account: String) -> String?
    func write(account: String, value: String)
    func delete(account: String)
}

struct KeychainStore: KeychainStoring {
    static let shared = KeychainStore()
    private static let service = "com.deepseek.chat"

    func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(account: String, value: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var newItem = query
            newItem[kSecValueData as String] = data
            SecItemAdd(newItem as CFDictionary, nil)
        }
    }

    func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
