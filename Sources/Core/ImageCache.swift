import Foundation
import SwiftUI
import CryptoKit
import os

/// 封面缓存：两级
///  1. 内存 NSCache（列表滚动时零 IO）
///  2. 磁盘 ~/Library/Application Support/VinylShelf/covers（离线可用）
final class ImageCache {
    static let shared = ImageCache()
    private let memory = NSCache<NSString, NSImage>()
    private let db: Database?

    init(db: Database? = nil) {
        self.db = db
        memory.countLimit = 400
        try? FileManager.default.createDirectory(at: AppPaths.images, withIntermediateDirectories: true)
    }

    /// 磁盘文件名 = URL 的 MD5 前 16 位。
    /// ⚠️ 必须用标准 MD5（CryptoKit），与 tools/fetch_covers.py 的 hashlib.md5 完全一致。
    /// 不要再手写哈希：Swift 的 `&*` wrapping 乘法与 Python 的 `& (2**64-1)`
    /// 在大数乘法下实测结果不同，会导致 App 认不出已下载的文件。
    func diskPath(for url: String) -> URL {
        AppPaths.images.appendingPathComponent("\(Self.md5(url)).jpg")
    }

    static func md5(_ s: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    /// 同步取图：内存 → 磁盘 → nil
    func image(for urlString: String) -> NSImage? {
        guard !urlString.isEmpty else { return nil }
        if let hit = memory.object(forKey: urlString as NSString) { return hit }
        let path = diskPath(for: urlString)
        if let img = NSImage(contentsOf: path) {
            memory.setObject(img, forKey: urlString as NSString)
            return img
        }
        return nil
    }

    /// 异步预热一批封面
    ///
    /// 两条通道（Discogs 图片 CDN 对非浏览器流量一律 403）：
    ///   1. WKWebView —— 走 WebKit 完整网络栈，能过 Cloudflare 挑战（主通道）
    ///   2. URLSession —— 系统 TLS 指纹，实践中同样被 403（保留作降级/未来 IP 变更）
    func warmCache(records: [Record], client: DiscogsClient, limit: Int,
                   onProgress: @escaping (String) -> Void) async -> Int {
        let targets = Array(
            records.filter { !$0.coverURL.isEmpty }
                   .filter { self.image(for: $0.coverURL) == nil }
                   .prefix(limit))
        guard !targets.isEmpty else { return 0 }

        onProgress("封面 \(targets.count) 张待下载（经 WebView）")
        let semaphore = Semaphore(value: 2)   // WebView 串行处理，并发别太高
        var done = 0
        var webviewHits = 0
        let lock = NSLock()

        await withTaskGroup(of: Bool.self) { group in
            for record in targets {
                group.addTask {
                    guard !Task.isCancelled else { return false }
                    await semaphore.wait()
                    defer { Task { await semaphore.signal() } }

                    let dest = self.diskPath(for: record.coverURL)
                    var bytes: Int = 0

                    // 通道 1：WebView
                    if let data = await WebImageLoader.shared.fetch(record.coverURL), !data.isEmpty {
                        try? FileManager.default.createDirectory(
                            at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try? data.write(to: dest, options: .atomic)
                        bytes = data.count
                        lock.lock(); webviewHits += 1; lock.unlock()
                    }
                    // 通道 2：URLSession 降级
                    if bytes == 0 {
                        if let b = await client.downloadImage(urlString: record.coverURL, to: dest), b > 0 {
                            bytes = b
                        }
                    }

                    if bytes > 0 {
                        self.db?.recordImage(url: record.coverURL, localPath: dest.path, bytes: bytes)
                    }
                    lock.lock()
                    done += bytes > 0 ? 1 : 0
                    let n = done
                    lock.unlock()
                    if n % 5 == 0 { onProgress("封面 \(n)/\(targets.count)") }
                    return bytes > 0
                }
            }
        }
        onProgress("封面完成 \(done)/\(targets.count)（WebView 成功 \(webviewHits)）")
        return done
    }

    /// 单张按需抓取。
    ///
    /// ⚠️ 通道顺序在 2026-10-05 调整过：URLSession 提到 WebView 之前。
    /// 之前注释里写「Discogs 图片 CDN 对非浏览器流量一律 403」——**这个结论是错的**。
    /// 重新实测（冷却后）`i.discogs.com` 裸请求就是 HTTP 200：
    ///   thumb(150×150) 3.4KB / cover(500×500) 44KB，均为合法 JPEG。
    /// 当初的 403 是自身高频重试触发的 Cloudflare **临时封禁**，不是能力边界。
    ///
    /// URLSession 快得多（毫秒级）且不依赖 WebView 挂载；
    /// WebView 保留作降级，但超时已从 15s 缩到 4s——窗口被 sheet 遮挡时
    /// WKWebView 会暂停渲染，15s 的等待会让每张图都拖成"整列空白"。
    func fetchOne(_ url: String, client: DiscogsClient) async -> Bool {
        if image(for: url) != nil { return true }
        let dest = diskPath(for: url)

        // 通道 1：URLSession（主）
        if let b = await client.downloadImage(urlString: url, to: dest), b > 0 {
            db?.recordImage(url: url, localPath: dest.path, bytes: b)
            return true
        }
        // 通道 2：WKWebView（降级）
        if let data = await WebImageLoader.shared.fetch(url), !data.isEmpty {
            try? FileManager.default.createDirectory(
                at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: dest, options: .atomic)
            db?.recordImage(url: url, localPath: dest.path, bytes: data.count)
            return true
        }
        return false
    }

    /// 批量预取（搜索结果缩略图用）。
    /// 逐行触发下载会让 50 行结果卡十几秒，这里并发预热。
    @discardableResult
    func prefetch(_ urls: [String], client: DiscogsClient, concurrency: Int = 6) async -> Int {
        let todo = urls.filter { !$0.isEmpty && image(for: $0) == nil }
        guard !todo.isEmpty else { return 0 }
        let sem = Semaphore(value: concurrency)
        var ok = 0
        let lock = NSLock()
        await withTaskGroup(of: Bool.self) { group in
            for u in todo.prefix(40) {
                group.addTask {
                    await sem.wait()
                    defer { Task { await sem.signal() } }
                    let hit = await self.fetchOne(u, client: client)
                    if hit { lock.lock(); ok += 1; lock.unlock() }
                    return hit
                }
            }
        }
        return ok
    }

    /// 磁盘占用
    func diskUsage() -> Int {
        guard let e = FileManager.default.enumerator(
            at: AppPaths.images,
            includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total = 0
        for case let url as URL in e {
            let v = try? url.resourceValues(forKeys: [.fileSizeKey])
            total += v?.fileSize ?? 0
        }
        return total
    }
}

/// 异步加载 SwiftUI Image
struct CachedCover: View {
    let url: String
    var width: CGFloat = 120
    var height: CGFloat = 120

    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image = image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        LinearGradient(
                            colors: [Color(white: 0.22), Color(white: 0.13)],
                            startPoint: .top, endPoint: .bottom))
                if failed || url.isEmpty {
                    VinylGlyph()
                        .foregroundStyle(.white.opacity(0.32))
                        .frame(width: width * 0.42, height: width * 0.42)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: url) {
            guard !url.isEmpty else { failed = true; return }
            if let hit = ImageCache.shared.image(for: url) {
                image = hit
                failed = false
                return
            }
            // ⚠️ 缓存未命中必须主动下载。
            // 之前这里直接 `failed = true`，注释写「交给详情视图顺带下载」——
            // 于是任何**新出现**的图（搜索结果缩略图、刚加进库的唱片）永远只显示占位符，
            // 直到用户点进详情页碰巧触发下载为止。
            if await ImageCache.shared.fetchOne(url, client: .shared),
               let hit = ImageCache.shared.image(for: url) {
                image = hit
                failed = false
            } else {
                failed = true
            }
        }
    }
}

/// 黑胶图形符号（占位图）
struct VinylGlyph: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(.black.opacity(0.55))
            Circle()
                .strokeBorder(.white.opacity(0.28), lineWidth: 0.8)
                .padding(6)
            Circle()
                .strokeBorder(.white.opacity(0.18), lineWidth: 0.6)
                .padding(12)
            Circle()
                .fill(Color.white.opacity(0.5))
                .frame(width: 12, height: 12)
        }
    }
}
