import Foundation

/// 内容指纹：用于索引幂等与变更检测（Tier 1-2）。
///
/// 必须跨进程 / 跨启动稳定，因此不能使用 Swift 标准库的 `Hasher`
/// （每次启动随机播种）。采用 FNV-1a 64 位实现，输出 16 位十六进制串。
enum ContentHash {
    static func fnv1a(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }
}
