import DeepSeekChatIndexing
import Foundation

/// 检索注入结果：注入上下文（system 前缀）+ 命中来源（Source 卡片复用）。
struct RetrievalResult: Equatable {
    var context: String
    var sources: [Source]
}

/// 检索注入契约：发送前对最后一条用户消息检索并注入（可替换为 mock / 远程）。
protocol RetrievalInjecting {
    func retrieve(for query: String) async -> RetrievalResult
}

/// 资料库检索注入（T3-3，ADR-0005 D4）：
/// 各启用库 top-k 检索 → 按文件去重 → token 预算裁剪（默认 6k，4~8k 可配）→
/// 生成上下文块 + `Source`（标题 = 文件名，url = 路径），UI 零新增概念。
actor LibraryRetrievalInjector: RetrievalInjecting {
    private let indexer: LibraryIndexing
    private let corporaProvider: @Sendable () -> [LibraryCorpus]
    private let tokenBudget: Int
    private let topKPerCorpus: Int
    private let estimator: CharacterTokenEstimator

    init(
        indexer: LibraryIndexing,
        corporaProvider: @escaping @Sendable () -> [LibraryCorpus],
        tokenBudget: Int = AppConfiguration.ragTokenBudget,
        topKPerCorpus: Int = AppConfiguration.ragTopKPerCorpus
    ) {
        self.indexer = indexer
        self.corporaProvider = corporaProvider
        self.tokenBudget = tokenBudget
        self.topKPerCorpus = topKPerCorpus
        self.estimator = CharacterTokenEstimator()
    }

    func retrieve(for query: String) async -> RetrievalResult {
        let corpora = corporaProvider().filter(\.isEnabled)
        guard !corpora.isEmpty, !query.isEmpty else {
            return RetrievalResult(context: "", sources: [])
        }

        // 各库 top-k，按文件去重（每文件保留最高分 chunk）。
        var bestByPath: [String: (corpusName: String, content: String, score: Int)] = [:]
        for corpus in corpora {
            guard
                let hits = try? await indexer.search(
                    corpusID: corpus.id,
                    query: query,
                    limit: topKPerCorpus
                )
            else {
                continue
            }
            for hit in hits where !hit.path.isEmpty {
                if let existing = bestByPath[hit.path] {
                    if hit.score > existing.score {
                        bestByPath[hit.path] = (corpus.name, hit.content, hit.score)
                    }
                } else {
                    bestByPath[hit.path] = (corpus.name, hit.content, hit.score)
                }
            }
        }
        guard !bestByPath.isEmpty else {
            return RetrievalResult(context: "", sources: [])
        }

        // token 预算约束（T3-3b）：装不下的命中丢弃；低于预算下限视为不注入。
        let sorted = bestByPath.sorted { $0.value.score > $1.value.score }
        var context = ""
        var sources: [Source] = []
        var usedTokens = 0
        for (path, entry) in sorted {
            let block = "[资料库：\(entry.corpusName)] \(path)\n\(entry.content)\n\n---\n"
            let blockTokens = estimator.estimateTokens(block) + 16
            guard usedTokens + blockTokens <= tokenBudget else { continue }
            context += block
            usedTokens += blockTokens
            sources.append(
                Source(
                    title: (path as NSString).lastPathComponent,
                    url: path
                )
            )
        }
        return RetrievalResult(
            context: context.trimmingCharacters(in: .whitespacesAndNewlines),
            sources: sources
        )
    }
}
