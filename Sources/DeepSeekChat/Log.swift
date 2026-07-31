import os

/// 统一的应用日志入口（os_log）。
///
/// 复用系统统一日志框架：崩溃与错误可被 Console.app / `log stream` 查看，
/// 不再使用 NSLog 直接打到 stderr。
enum AppLog {
    /// 数据库与存储相关（SQLite / GRDB / 迁移）。
    static let storage = Logger(subsystem: "com.deepseek.chat", category: "storage")
}
