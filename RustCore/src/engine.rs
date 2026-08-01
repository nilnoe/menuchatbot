//! embedding 抽象与 mock 实现（Tier 3，ADR-0005 D5）。
//!
//! 方向：默认 `mock-embeddings`（确定性、零依赖、可离线构建，单测与
//! Swift FFI 集成测试先用它校准）；真实本地模型（candle）或远程
//! OpenAI 兼容 embedding 接入时实现同一 [`Embedder`] trait，替换注入点即可，
//! 调用方（索引 / 检索）不感知实现差异。

/// mock embedding 维度。128 维足够 keyword 级区分度，且索引文件体积可控
/// （10 万 chunk ≈ 128 × 4B × 10^5 ≈ 51MB 未压缩；量化后可再降）。
pub const MOCK_DIM: usize = 128;

/// embedding 抽象：任何实现（mock / candle / 远程）都可注入。
pub trait Embedder: Send + Sync {
    fn dim(&self) -> usize;
    fn embed(&self, text: &str) -> Vec<f32>;
}

/// 确定性 mock embedding：ASCII 词元 + 字符 bigram 哈希到固定维度桶，
/// L2 归一化。同一文本在任何进程 / 任何时刻都得到同一向量。
pub struct MockEmbedder {
    dim: usize,
}

impl MockEmbedder {
    pub fn new(dim: usize) -> Self {
        Self { dim: dim.max(8) }
    }
}

impl Default for MockEmbedder {
    fn default() -> Self {
        Self::new(MOCK_DIM)
    }
}

impl Embedder for MockEmbedder {
    fn dim(&self) -> usize {
        self.dim
    }

    fn embed(&self, text: &str) -> Vec<f32> {
        let mut vec = vec![0f32; self.dim];
        // ASCII 词元（CJK 文本整段会被 split 成一个长词，故再走 bigram）。
        for word in text.split(|c: char| !c.is_ascii_alphanumeric()) {
            if !word.is_empty() {
                add_hash(&mut vec, word.as_bytes(), 1.0);
            }
        }
        // 字符 bigram：CJK 与 ASCII 混合文本都覆盖；过滤空白与标点。
        let chars: Vec<char> = text.chars().filter(|c| c.is_alphanumeric()).collect();
        for pair in chars.windows(2) {
            let mut buf = Vec::with_capacity(8);
            buf.extend_from_slice(pair[0].to_string().as_bytes());
            buf.extend_from_slice(pair[1].to_string().as_bytes());
            add_hash(&mut vec, &buf, 1.0);
        }
        // 单字符文本补充（如查询只有一个字时）。
        if chars.len() == 1 {
            add_hash(&mut vec, chars[0].to_string().as_bytes(), 1.0);
        }
        normalize(&mut vec);
        vec
    }
}

fn add_hash(vec: &mut [f32], bytes: &[u8], weight: f32) {
    let h1 = fnv1a(bytes);
    let bucket = (h1 as usize) % vec.len();
    vec[bucket] += weight;
    // 二次带符号哈希：同一 token 符号确定（相关文本同向累加），
    // 无关 token 落入同桶时正负相消 → 无关文档相似度趋近 0。
    let h2 = fnv1a(&h1.to_be_bytes());
    let bucket2 = ((h2 >> 1) as usize) % vec.len();
    vec[bucket2] += if h2 & 1 == 0 {
        weight * 0.5
    } else {
        -weight * 0.5
    };
}

fn normalize(vec: &mut [f32]) {
    let norm: f32 = vec.iter().map(|v| v * v).sum::<f32>().sqrt();
    if norm > 0.0 {
        for v in vec.iter_mut() {
            *v /= norm;
        }
    }
}

/// FNV-1a 64：确定性、跨进程稳定（不依赖系统随机种子）。
pub fn fnv1a(bytes: &[u8]) -> u64 {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for &b in bytes {
        hash ^= b as u64;
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    hash
}

/// 余弦相似度（向量已归一化 → 点积；结果裁剪到 [0, 1]）。
pub fn cosine(a: &[f32], b: &[f32]) -> f32 {
    let n = a.len().min(b.len());
    if n == 0 {
        return 0.0;
    }
    let mut dot = 0f32;
    for i in 0..n {
        dot += a[i] * b[i];
    }
    dot.clamp(0.0, 1.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mock_embedding_is_deterministic() {
        let embedder = MockEmbedder::default();
        assert_eq!(embedder.embed("香蕉牛奶"), embedder.embed("香蕉牛奶"));
        assert_eq!(embedder.embed("苹果"), embedder.embed("苹果"));
    }

    #[test]
    fn mock_embedding_dim_and_norm() {
        let embedder = MockEmbedder::default();
        let vec = embedder.embed("Swift 并发编程实践");
        assert_eq!(vec.len(), MOCK_DIM);
        let norm: f32 = vec.iter().map(|v| v * v).sum::<f32>().sqrt();
        assert!((norm - 1.0).abs() < 1e-4, "向量应 L2 归一化");
    }

    #[test]
    fn similar_text_scores_higher_than_unrelated() {
        let embedder = MockEmbedder::default();
        let query = embedder.embed("香蕉牛奶");
        let related = embedder.embed("香蕉牛奶很好喝");
        let unrelated = embedder.embed("苹果派与天气预报");
        assert!(
            cosine(&query, &related) > cosine(&query, &unrelated),
            "语义相关文本相似度应高于无关文本"
        );
    }

    #[test]
    fn fnv1a_stable_across_calls() {
        assert_eq!(fnv1a(b"hello"), fnv1a(b"hello"));
        assert_ne!(fnv1a(b"hello"), fnv1a(b"hellp"));
    }
}
