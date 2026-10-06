import Foundation

enum DiscogsError: LocalizedError {
    case notConfigured
    case invalidToken(String)
    case rateLimited(retryAfter: Int)
    case http(Int, String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "尚未配置 Discogs Personal Access Token"
        case .invalidToken(let msg):
            return "Token 无效: \(msg)"
        case .rateLimited(let s):
            return "触发 Discogs 速率限制，\(s) 秒后重试"
        case .http(let code, let msg):
            return "HTTP \(code): \(msg)"
        case .decoding(let msg):
            return "数据解析失败: \(msg)"
        }
    }
}

/// Discogs REST API 客户端
/// - 认证：Personal Access Token（`Authorization: Discogs token=xxx`）
/// - 限流：认证后 60 req/min（滚动 60 秒窗口），读取 X-Discogs-Ratelimit-Remaining 自适应节流
/// - 429：按 Retry-After 退避重试
final class DiscogsClient {
    private let base = "https://api.discogs.com"
    private let session: URLSession
    private let userAgent: String
    private var token: String?

    /// 上次请求时间戳，用于最小间隔节流
    private var lastRequestAt: Date = Date.distantPast
    private let minInterval: TimeInterval = 1.05   // 60/min → 1.05s 间隔，留 5% 余量
    private let throttleQueue = DispatchQueue(label: "discogs.throttle", attributes: .concurrent)

    /// 当前窗口剩余额度（服务端告知），-1 = 未知
    private(set) var rateLimitRemaining: Int = -1
    /// 429 后需要等待到的时刻
    private var cooldownUntil: Date = .distantPast

    var onRateLimitUpdate: ((Int) -> Void)?

    /// 全局共享实例。
    /// CachedCover 之类的视图层没有 AppState 引用，拿不到 client，
    /// 缓存未命中时需要一个带 token 的入口去下载图片。
    static let shared = DiscogsClient()

    init(userAgent: String = "VinylShelf/1.0 (+https://github.com/local/vinylshelf)") {
        self.userAgent = userAgent
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.httpAdditionalHeaders = ["Accept": "application/vnd.discogs.v2.discogs+json"]
        self.session = URLSession(configuration: cfg)
    }

    func setToken(_ t: String?) { token = t?.trimmed.nilIfEmpty }

    var hasToken: Bool { token != nil }

    // MARK: - 请求内核

    private func waitForSlot() async throws {
        // 429 冷却
        let now = Date()
        if now < cooldownUntil {
            let sleep = cooldownUntil.timeIntervalSince(now)
            try? await Task.sleep(nanoseconds: UInt64(sleep * 1_000_000_000))
        }
        // 最小间隔
        let elapsed = Date().timeIntervalSince(lastRequestAt)
        if elapsed < minInterval {
            try? await Task.sleep(nanoseconds: UInt64((minInterval - elapsed) * 1_000_000_000))
        }
        lastRequestAt = Date()
    }

    private func perform(_ path: String,
                         method: String = "GET",
                         query: [String: String] = [:],
                         authenticated: Bool = true,
                         retryOn429: Int = 4) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: base + path) else { throw DiscogsError.http(-1, "bad URL: \(path)") }
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if authenticated, let t = token {
            req.setValue("Discogs token=\(t)", forHTTPHeaderField: "Authorization")
        }

        var attempt = 0
        while true {
            let t0 = Date()
            try await waitForSlot()
            if ProcessInfo.processInfo.environment["VINYLSHELF_TRACE"] != nil {
                FileHandle.standardError.write(Data(
                    "  → REQ \(path)  排队 \(String(format: "%.2f", Date().timeIntervalSince(t0)))s\n".utf8))
            }

            let (data, resp) = try await send(req)
            if ProcessInfo.processInfo.environment["VINYLSHELF_TRACE"] != nil {
                FileHandle.standardError.write(Data(
                    "  ← RSP \(path)  HTTP \(resp.statusCode)  \(data.count)B  总耗时 \(String(format: "%.2f", Date().timeIntervalSince(t0)))s\n".utf8))
            }
            // 记录额度
            if let rem = resp.value(forHTTPHeaderField: "X-Discogs-Ratelimit-Remaining"),
               let v = Int(rem) {
                let changed = v != rateLimitRemaining
                rateLimitRemaining = v
                if changed { onRateLimitUpdate?(v) }
            }

            switch resp.statusCode {
            case 200...299:
                return (data, resp)
            case 429:
                attempt += 1
                if attempt > retryOn429 { throw DiscogsError.rateLimited(retryAfter: 60) }
                var wait = Int(resp.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 0
                if wait <= 0 { wait = Int(max(15, minInterval * 12)) }   // 无 Retry-After 时保守退避
                wait = min(wait, 120)
                cooldownUntil = Date().addingTimeInterval(TimeInterval(wait))
                rateLimitRemaining = 0
                onRateLimitUpdate?(0)
                continue
            case 401, 403:
                let msg = Self.errorMessage(from: data)
                throw DiscogsError.invalidToken(msg)
            default:
                let msg = Self.errorMessage(from: data)
                throw DiscogsError.http(resp.statusCode, msg)
            }
        }
    }

    private func send(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data, HTTPURLResponse), Error>) in
            let task = session.dataTask(with: req) { data, resp, err in
                if let err = err {
                    cont.resume(throwing: err)
                    return
                }
                guard let http = resp as? HTTPURLResponse else {
                    cont.resume(throwing: DiscogsError.http(-1, "非 HTTP 响应"))
                    return
                }
                cont.resume(returning: (data ?? Data(), http))
            }
            task.resume()
        }
    }

    private static func errorMessage(from data: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let m = obj["message"] as? String { return m }
        return String(data: data.prefix(200), encoding: .utf8) ?? "未知错误"
    }

    private func decode<T: Decodable>(_ type: T.Type, _ path: String, query: [String: String] = [:]) async throws -> T {
        let (data, _) = try await perform(path, query: query)
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw DiscogsError.decoding("\(error) | body 前 200 字节: \(String(data: data.prefix(200), encoding: .utf8) ?? "")")
        }
    }

    // MARK: - 身份与文件夹

    /// 验证 token 并取回用户名
    func identity() async throws -> DiscogsIdentity {
        guard token != nil else { throw DiscogsError.notConfigured }
        return try await decode(DiscogsIdentity.self, "/oauth/identity")
    }

    func folders(username: String) async throws -> [DiscogsFolder] {
        let page: DiscogsFolderList = try await decode(
            DiscogsFolderList.self, "/users/\(username)/collection/folders")
        return page.folders ?? []
    }

    /// 拉取 collection 某文件夹的一页。
    /// 实测：路径必须是 /collection/folders/{id}/releases，/collection 直接 404
    func collectionPage(username: String, folderId: Int, page: Int, perPage: Int = 100) async throws -> DiscogsCollectionPage {
        return try await decode(
            DiscogsCollectionPage.self,
            "/users/\(username)/collection/folders/\(folderId)/releases",
            query: [
                "page": String(page),
                "per_page": String(perPage),
                "sort": "artist",
                "sort_order": "asc"
            ])
    }

    /// 拉取 release 完整详情（补齐 country / tracklist / notes / images）
    func release(id: Int) async throws -> DiscogsRelease {
        return try await decode(DiscogsRelease.self, "/releases/\(id)")
    }

    /// 同上，但同时返回原始 JSON（用于本地全量留存）
    func rawReleaseJSON(id: Int) async throws -> Data {
        let (data, _) = try await perform("/releases/\(id)")
        return data
    }

    /// 搜索数据库
    func search(query: String,
                type: String = "release",
                year: String? = nil,
                genre: String? = nil,
                style: String? = nil,
                country: String? = nil,
                label: String? = nil,
                format: String? = nil,
                artist: String? = nil,
                sort: String? = nil,
                page: Int = 1,
                perPage: Int = 50) async throws -> DiscogsSearchPage {
        var q: [String: String] = [
            "q": query,
            "type": type,
            "page": String(page),
            "per_page": String(perPage)
        ]
        if let v = year, !v.isEmpty { q["year"] = v }
        if let v = genre, !v.isEmpty { q["genre"] = v }
        if let v = style, !v.isEmpty { q["style"] = v }
        if let v = country, !v.isEmpty { q["country"] = v }
        if let v = label, !v.isEmpty { q["label"] = v }
        if let v = format, !v.isEmpty { q["format"] = v }
        if let v = artist, !v.isEmpty { q["artist"] = v }
        // 相关度排序时不能传 sort，Discogs 会返回 400
        if let v = sort?.trimmed.nilIfEmpty { q["sort"] = v }
        return try await decode(DiscogsSearchPage.self, "/database/search", query: q)
    }

    // MARK: - 写操作（本地 → Discogs）
    //
    // ⚠️ 能力边界是实测出来的，不是照抄文档：
    //   OPTIONS /users/{u}/collection/folders/{f}/releases/{id}
    //     → HTTP 405，响应头 `Allow: POST`
    //   也就是说该端点**只接受 POST**，Discogs 没有开放「删除收藏项」的 API。
    //   同理 PUT/PATCH 改备注与评分也不可用——写回方向只有「加入收藏」。

    /// 把 release 加入指定收藏文件夹。返回是否成功（已存在时 Discogs 仍返回 2xx）
    func addToCollection(username: String, folderId: Int, releaseId: Int) async throws {
        _ = try await perform(
            "/users/\(username)/collection/folders/\(folderId)/releases/\(releaseId)",
            method: "POST")
    }

    /// 加入想读单（wantlist）
    func addToWantlist(username: String, releaseId: Int) async throws {
        _ = try await perform("/users/\(username)/wantlist/\(releaseId)", method: "PUT")
    }

    /// 拉取想读单。
    /// ⚠️ 账号没有想读单时 Discogs 返回 **404**（而不是空列表），
    ///    这里翻译成 nil，让上层显示「0 条」而不是报错。
    func wantlist(username: String, page: Int, perPage: Int = 100) async throws -> DiscogsWantlistPage? {
        do {
            return try await decode(
                DiscogsWantlistPage.self, "/users/\(username)/wantlist",
                query: ["page": String(page), "per_page": String(perPage)])
        } catch DiscogsError.http(let code, _) where code == 404 {
            return nil
        }
    }

    // MARK: - 图片下载

    /// 下载封面到本地。i.discogs.com 对直连有 Cloudflare 防护，
    /// 实测带正常 UA + Referer 才可能通过；失败返回 nil，UI 走占位图。
    func downloadImage(urlString: String, to destination: URL) async -> Int? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://www.discogs.com/", forHTTPHeaderField: "Referer")
        req.timeoutInterval = 20

        do {
            let (data, resp) = try await withCheckedThrowingContinuation {
                (cont: CheckedContinuation<(Data, HTTPURLResponse), Error>) in
                session.dataTask(with: req) { d, r, e in
                    if let e = e { cont.resume(throwing: e); return }
                    guard let h = r as? HTTPURLResponse else {
                        cont.resume(throwing: DiscogsError.http(-1, "非 HTTP")); return
                    }
                    cont.resume(returning: (d ?? Data(), h))
                }.resume()
            }
            guard (200...299).contains(resp.statusCode), data.count > 500 else { return nil }
            try? FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
            return data.count
        } catch {
            return nil
        }
    }
}
