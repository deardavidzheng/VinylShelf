import Foundation
import Security

/// Token 存储
///
/// ⚠️ 不用 Keychain。Keychain 项的 ACL 绑定「写入它的那个二进制」，
/// 而本 App 每次重新构建后二进制哈希都会变 → 旧项的 ACL 不再匹配，
/// 每次读取都触发系统密码框挡住窗口。
/// 改存 App 私有目录，权限 600（仅当前用户可读写），对单机 App 等效安全。
enum Keychain {
    private static func file(_ account: String) -> URL {
        AppPaths.support.appendingPathComponent("\(account).secret")
    }

    static func set(_ value: String?, account: String) {
        let url = file(account)
        guard let v = value?.trimmed.nilIfEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        do {
            try v.write(to: url, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: url.path)
        } catch {
            FileHandle.standardError.write(Data("token 写入失败: \(error)\n".utf8))
        }
    }

    static func get(account: String) -> String? {
        guard let s = try? String(contentsOf: file(account), encoding: .utf8) else {
            return nil
        }
        return s.trimmed.nilIfEmpty
    }

    static func delete(account: String) {
        try? FileManager.default.removeItem(at: file(account))
    }
}

/// 应用数据目录
enum AppPaths {
    static var support: URL {
        let fm = FileManager.default
        let base = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                              appropriateFor: nil, create: true)
        let dir = (base ?? fm.temporaryDirectory).appendingPathComponent("VinylShelf", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var database: URL { support.appendingPathComponent("library.sqlite") }
    static var images: URL { support.appendingPathComponent("covers", isDirectory: true) }
    static var exportDir: URL { support.appendingPathComponent("exports", isDirectory: true) }
    /// 「本 App 是否已保存过 token」的非敏感标记。
    /// 存在这个文件不代表 token 还在（可能被用户删了），但它能在
    /// **不触碰 KeyChain、不触发系统授权框**的前提下让 UI 知道该显示什么。
    static var tokenMarker: URL { support.appendingPathComponent("has-token") }
}

/// 判断本 App 是否保存过 token —— 只读本地标记文件，不访问 Keychain
func KeychainItemExists() -> Bool {
    FileManager.default.fileExists(atPath: AppPaths.tokenMarker.path)
}
