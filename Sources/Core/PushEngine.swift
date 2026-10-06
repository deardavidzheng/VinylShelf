import Foundation

/// 本地 → Discogs 的写回引擎（双向同步的「上行」方向）。
///
/// ## API 能力边界（2026-10-05 实测，非照抄文档）
///
/// | 操作 | 端点 | 结果 |
/// |---|---|---|
/// | 加入收藏 | `POST /users/{u}/collection/folders/{f}/releases/{id}` | ✅ 201 |
/// | 删除收藏项 | 同一路径 DELETE / PUT / PATCH | ❌ 一律 405，响应头 `Allow: POST` |
/// | 加入想读单 | `PUT /users/{u}/wantlist/{id}` | ⚠️ 未实测（该账号无 wantlist，路径探针 404） |
/// | 读想读单 | `GET /users/{u}/wantlist` | ⚠️ 无想读单时返回 404 而非空列表 |
///
/// **重要后果**：Discogs 根本没开放「删除收藏项」的 API。
/// 所以「双向同步」在这个方向上只可能是**单向增量的**——本地新增能推上去，
/// 本地删除推不上去。UI 上必须如实告知，不能做成一个看起来能删、实际删不掉的按钮。
/// 另：收藏项的评分 / 备注同样没有可用的写端点，仍属纯本地字段。
final class PushEngine {

    /// 供 UI 展示的能力说明，避免做出无法兑现的承诺
    static let removalNotice = "Discogs 未开放删除收藏项的 API（该端点只接受 POST），本地删除需在网页端手动处理。"

    private let client: DiscogsClient
    private let db: Database
    private let imageCache: ImageCache
    private let sync: SyncEngine

    /// 目标收藏文件夹。folder 0 是「全部」这个伪文件夹，不能作为写入目标。
    private var targetFolderId: Int?
    private(set) var username: String = ""

    init(client: DiscogsClient, db: Database, imageCache: ImageCache, sync: SyncEngine) {
        self.client = client
        self.db = db
        self.imageCache = imageCache
        self.sync = sync
    }

    /// 解析用户名与可写入的收藏文件夹
    @discardableResult
    func prepare(username: String) async -> Int? {
        self.username = username
        guard let folders = try? await client.folders(username: username) else { return nil }
        // folder 0 = All（伪文件夹，不可写），取第一个真实文件夹
        let target = folders
            .compactMap { $0.id }
            .filter { $0 > 0 }
            .min()
        targetFolderId = target
        return target
    }

    // MARK: - 单条写回

    /// 把一条 release 加入 Discogs 收藏。
    /// - Returns: 面向用户的中文结果说明（空串表示未执行）
    func addToDiscogsCollection(releaseId: Int) async -> String {
        guard releaseId > 0 else { return "" }
        guard !username.isEmpty else { return "未连接 Discogs，无法写入" }

        let folder: Int
        if let cached = targetFolderId {
            folder = cached
        } else {
            folder = (await prepare(username: username)) ?? 1
        }
        do {
            try await client.addToCollection(username: username, folderId: folder, releaseId: releaseId)
            // 收藏成功后本地这条 instance_id 仍是 0；下次同步时 upsert 会「收养」它
            // （见 Database.findIdByInstance），不会产生重复行。
            return "已同步到 Discogs 收藏（文件夹 \(folder)）"
        } catch {
            return "写入 Discogs 失败：\(error.localizedDescription)"
        }
    }

    /// 加入 Discogs 想读单
    func addToWantlist(releaseId: Int) async -> String {
        guard releaseId > 0 else { return "" }
        guard !username.isEmpty else { return "未连接 Discogs，无法写入" }
        do {
            try await client.addToWantlist(username: username, releaseId: releaseId)
            return "已加入 Discogs 想读单"
        } catch {
            return "加入想读单失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 批量写回

    /// 待推送的本地记录：已关联 Discogs release、但还没有 instance_id
    /// （即通过搜索添加进来、尚未进入 Discogs 收藏的那些）
    func pendingPush() throws -> [Record] {
        try db.allRecords().filter(\.isPendingPush)
    }

    /// 把所有待推送记录写回 Discogs
    @discardableResult
    func pushAllPending(max: Int = 200,
                        onProgress: @escaping (String) -> Void = { _ in }) async -> (ok: Int, failed: Int) {
        guard !username.isEmpty else {
            onProgress("未连接 Discogs")
            return (0, 0)
        }
        guard let pending = try? pendingPush(), !pending.isEmpty else {
            onProgress("没有待推送的记录")
            return (0, 0)
        }
        let batch = Array(pending.prefix(max))
        var ok = 0, failed = 0
        for (i, r) in batch.enumerated() {
            onProgress("推送 \(i + 1)/\(batch.count)：\(r.title)")
            do {
                try await client.addToCollection(username: username,
                                                 folderId: targetFolderId ?? 1,
                                                 releaseId: r.discogsReleaseId)
                ok += 1
            } catch {
                failed += 1
            }
        }
        onProgress("推送完成：成功 \(ok)，失败 \(failed)")
        return (ok, failed)
    }

    // MARK: - wantlist 导入

    struct WantlistImportResult {
        var added = 0
        var existing = 0
        var enriched = 0
        var covers = 0
        var message = ""
    }

    /// 导入 Discogs 想读单：拉列表 → 建占位记录(status=wanted) → 补全详情 → 下载封面
    func importWantlist(maxItems: Int = 300,
                        downloadImages: Bool = true,
                        onProgress: @escaping (String) -> Void = { _ in }) async -> WantlistImportResult {
        var out = WantlistImportResult()
        guard !username.isEmpty else {
            out.message = "未连接 Discogs"
            return out
        }

        // 1) 翻页拉取
        var items: [DiscogsSearchResult] = []
        var page = 1
        while items.count < maxItems {
            guard let result = try? await client.wantlist(username: username, page: page) else {
                out.message = items.isEmpty
                    ? "该账号没有想读单（Discogs 对空 wantlist 返回 404）"
                    : "想读单拉取中断，已导入 \(items.count) 条"
                break
            }
            let batch = result.wants ?? []
            if batch.isEmpty {
                out.message = items.isEmpty
                    ? "该账号没有想读单（Discogs 对空 wantlist 返回 404）"
                    : "想读单导入完成，共 \(items.count) 条"
                break
            }
            items.append(contentsOf: batch)
            let pages = result.pagination?.pages ?? 1
            if page >= pages { 
                out.message = "想读单导入完成，共 \(items.count) 条"
                break 
            }
            page += 1
        }
        if items.isEmpty {
            if out.message.isEmpty { out.message = "该账号没有想读单" }
            return out
        }
        if items.count > maxItems { items = Array(items.prefix(maxItems)) }

        // 2) 落库
        var toEnrich: [Record] = []
        for item in items {
            guard let rid = item.id, rid > 0 else { continue }
            if let e = try? db.records(releaseId: rid).first {
                // 已在库：若是拥有中的收藏，跳过；否则补标记为「想拥有」
                if e.statusLocal == "owned" { out.existing += 1; continue }
                try? db.updateLocalFields(id: e.id, statusLocal: "wanted")
                out.existing += 1
                continue
            }
            let rec = Record.placeholder(from: item, statusLocal: "wanted")
            if let rowId = try? db.upsert(rec) {
                out.added += 1
                if let saved = try? db.record(id: rowId) { toEnrich.append(saved) }
            }
        }

        // 3) 补全详情（每条 1 次请求，受客户端 1.05s 节流保护）
        if !toEnrich.isEmpty {
            onProgress("正在补全 \(toEnrich.count) 条详情…")
            if await sync.enrich(records: toEnrich) { out.enriched = toEnrich.count }
            let fresh = (try? toEnrich.compactMap { try db.record(id: $0.id) }) ?? []
            toEnrich = fresh
        }

        // 4) 封面
        if downloadImages {
            for (i, r) in toEnrich.enumerated() {
                onProgress("下载封面 \(i + 1)/\(toEnrich.count)：\(r.title)")
                if !r.coverURL.isEmpty, await imageCache.fetchOne(r.coverURL, client: client) {
                    out.covers += 1
                }
            }
        }

        if out.message.isEmpty {
            out.message = "想读单导入完成：新增 \(out.added)，已存在 \(out.existing)，详情 \(out.enriched)，封面 \(out.covers)"
        }
        return out
    }
}
