import Foundation

/// 稳定哈希（FNV-1a 64bit）
///
/// ⚠️ 不要用 Swift 的 `String.hashValue` 做持久化指纹：
/// 它带进程级随机种子，每次启动都不同，跨进程比较永远不相等，
/// 会让「增量同步」在每次重启后都退化成全量重拉。
enum StableHash {
    static func fnv1a(_ s: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let prime: UInt64 = 0x1000_0000_01b3
        for byte in Array(s.utf8) {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return String(hash, radix: 16)
    }
}
