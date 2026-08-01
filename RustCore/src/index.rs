//! 最小索引核心（Tier 2 骨架）。
//!
//! Tier 2 只打通 ABI 与数据往返：内存中文档存储 + 词元命中打分检索，
//! 无 embedding / 向量。Tier 3 在保留 C ABI 的前提下替换为
//! candle embedding + 向量索引（usearch 或自写 brute-force）。
//! 索引是派生数据：本模块可整体删除重建，SQLite 仍是事实源。

use std::collections::HashMap;

/// 索引格式版本：内部格式变化时递增，Swift 侧据此触发 rebuild。
pub const INDEX_VERSION: i32 = 1;

#[derive(Debug, Clone, PartialEq)]
pub struct Doc {
    pub id: String,
    pub content: String,
    pub namespace: String,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Hit {
    pub id: String,
    pub score: i64,
    pub content: String,
}

#[derive(Debug)]
pub struct IndexCore {
    docs: HashMap<String, Doc>,
    namespace: String,
}

impl IndexCore {
    pub fn new(namespace: String) -> Self {
        IndexCore {
            docs: HashMap::new(),
            namespace,
        }
    }

    pub fn namespace(&self) -> &str {
        &self.namespace
    }

    pub fn document_count(&self) -> usize {
        self.docs.len()
    }

    /// 写入 / 更新一条文档；`namespace` 为空时使用索引默认命名空间。
    pub fn upsert(&mut self, id: String, content: String, namespace: Option<String>) {
        let namespace = namespace.unwrap_or_else(|| self.namespace.clone());
        self.docs.insert(
            id.clone(),
            Doc {
                id,
                content,
                namespace,
            },
        );
    }

    pub fn delete(&mut self, id: &str) -> Result<(), String> {
        match self.docs.remove(id) {
            Some(_) => Ok(()),
            None => Err(format!("document not found: {}", id)),
        }
    }

    /// 词元命中打分检索：查询拆词后对每个词元统计内容出现次数（大小写不敏感），
    /// 按得分降序、id 升序返回前 `limit` 条；`namespace` 为空时不过滤。
    pub fn search(&self, query: &str, limit: usize, namespace: Option<&str>) -> Vec<Hit> {
        let tokens = tokenize(query);
        let mut hits: Vec<Hit> = self
            .docs
            .values()
            .filter(|doc| namespace.is_none_or(|ns| doc.namespace == ns))
            .filter_map(|doc| {
                let score: i64 = tokens
                    .iter()
                    .map(|token| count_occurrences(&doc.content, token))
                    .sum();
                if score > 0 {
                    Some(Hit {
                        id: doc.id.clone(),
                        score,
                        content: doc.content.clone(),
                    })
                } else {
                    None
                }
            })
            .collect();
        hits.sort_by(|a, b| b.score.cmp(&a.score).then_with(|| a.id.cmp(&b.id)));
        hits.truncate(limit);
        hits
    }

    pub fn clear(&mut self) {
        self.docs.clear();
    }
}

fn tokenize(query: &str) -> Vec<String> {
    query
        .split(|c: char| !(c.is_alphanumeric() || c == '_'))
        .filter(|s| !s.is_empty())
        .map(|s| s.to_lowercase())
        .collect()
}

fn count_occurrences(haystack: &str, needle: &str) -> i64 {
    let haystack = haystack.to_lowercase();
    haystack.matches(needle).count() as i64
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_index() -> IndexCore {
        let mut ix = IndexCore::new("history".to_string());
        ix.upsert("m1".to_string(), "苹果与香蕉都是水果".to_string(), None);
        ix.upsert("m2".to_string(), "今天天气很好".to_string(), None);
        ix.upsert("m3".to_string(), "香蕉牛奶".to_string(), None);
        ix.upsert(
            "lib1".to_string(),
            "苹果种植指南".to_string(),
            Some("library".to_string()),
        );
        ix
    }

    #[test]
    fn upsert_and_count() {
        let mut ix = IndexCore::new("history".to_string());
        assert_eq!(ix.document_count(), 0);
        ix.upsert("a".to_string(), "内容".to_string(), None);
        assert_eq!(ix.document_count(), 1);
        ix.upsert("a".to_string(), "更新内容".to_string(), None);
        assert_eq!(ix.document_count(), 1, "同 id upsert 应幂等");
    }

    #[test]
    fn delete_roundtrip() {
        let mut ix = make_index();
        ix.delete("m1").unwrap();
        assert_eq!(ix.document_count(), 3);
        assert!(ix.delete("missing").is_err());
    }

    #[test]
    fn search_ranks_by_token_hits() {
        let ix = make_index();
        let hits = ix.search("香蕉", 10, None);
        assert_eq!(hits.len(), 2, "m2 与 lib1 不含关键词");
        assert_eq!(hits[0].id, "m1", "同分按 id 升序：m1 < m3");
        assert_eq!(hits[1].id, "m3");
        assert_eq!(hits[0].score, 1);
    }

    #[test]
    fn search_respects_namespace() {
        let ix = make_index();
        let hits = ix.search("苹果", 10, Some("library"));
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].id, "lib1");
    }

    #[test]
    fn search_empty_and_missing() {
        let ix = make_index();
        assert!(ix.search("", 10, None).is_empty());
        assert!(ix.search("不存在的词", 10, None).is_empty());
    }

    #[test]
    fn search_case_insensitive_and_limit() {
        let mut ix = IndexCore::new("history".to_string());
        for i in 0..20 {
            ix.upsert(format!("m{}", i), "Swift Swift".to_string(), None);
        }
        let hits = ix.search("swift", 5, None);
        assert_eq!(hits.len(), 5);
        assert_eq!(hits[0].score, 2);
    }

    #[test]
    fn clear_removes_everything() {
        let mut ix = make_index();
        ix.clear();
        assert_eq!(ix.document_count(), 0);
    }
}
