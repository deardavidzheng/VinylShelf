import Foundation
import os

/// 同步引擎：Discogs → 本地
///
/// 增量策略（关键：collection 端点实测 0/299 提供 date_changed，只给 date_added，
/// 所以不能靠时间戳判断增量，必须用字段指纹）：
///   阶段 1 collection：分页拉列表 → 与本地 fingerprint 比对
///        · 本地没有        → 新增
///        · fingerprint 不同 → 标记为需要刷新详情
///        · 相同            → 跳过
///        · 本地有但线上没有 → 删除
///   阶段 2 detail：只对「新增」或「指纹变化」的条目请求 /releases/{id}，
///        补齐 country / tracklist / notes / images，并记录 date_changed 做二次确认。
///        日常无变更时，299 张的同步只需 3 个请求（100/页），而不是 299 个。
final class SyncEngine: ObservableObject {

    enum Phase: Equatable {
        // SyncReport 含时间字段不可自动 Equatable，这里手工实现
        case idle
        case authenticating
        case collection(current: Int, total: Int)
        case detail(current: Int, total: Int)
        case images
        case done(stats: SyncReport)
        case failed(String)

        static func == (a: Phase, b: Phase) -> Bool {
            switch (a, b) {
            case (.idle, .idle), (.authenticating, .authenticating), (.images, .images):
                return true
            case let (.collection(c1, t1), .collection(c2, t2)): return c1 == c2 && t1 == t2
            case let (.detail(c1, t1), .detail(c2, t2)): return c1 == c2 && t1 == t2
            case let (.done(s1), .done(s2)): return s1.summary == s2.summary
            case let (.failed(m1), .failed(m2)): return m1 == m2
            default: return false
            }
        }

        var isRunning: Bool {
            switch self {
            case .idle, .done, .failed: return false
            default: return true
            }
        }

        var label: String {
            switch self {
            case .idle: return "空闲"
            case .authenticating: return "验证 Token…"
            case .collection(let c, let t): return "拉取收藏列表 \(c)/\(t)"
            case .detail(let c, let t): return "拉取详情 \(c)/\(t)"
            case .images: return "下载封面…"
            case .done: return "完成"
            case .failed(let m): return "失败：\(m)"
            }
        }

        var fraction: Double {
            switch self {
            case .collection(let c, let t): return t > 0 ? Double(c) / Double(t) * 0.25 : 0
            case .detail(let c, let t): return 0.25 + (t > 0 ? Double(c) / Double(t) * 0.7 : 0)
            case .images: return 0.98
            case .done: return 1.0
            default: return 0
            }
        }
    }

    struct SyncReport: Equatable {
        var added = 0
        var updated = 0
        var removed = 0
        var unchanged = 0
        var detailsFetched = 0
        var imagesCached = 0
        var durationSeconds: Double = 0
        var rateLimitRemaining: Int = -1

        var summary: String {
            var parts: [String] = []
            if added > 0 { parts.append("新增 \(added)") }
            if updated > 0 { parts.append("更新 \(updated)") }
            if removed > 0 { parts.append("移除 \(removed)") }
            if unchanged > 0 { parts.append("无变化 \(unchanged)") }
            if parts.isEmpty { return "本地已是最新" }
            parts.append(String(format: "耗时 %.1f 秒", durationSeconds))
            return parts.joined(separator: " · ")
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published var username: String = ""   // 设置页验证后需要直接回填
    @Published private(set) var rateLimitRemaining: Int = -1
    @Published private(set) var lastSyncDate: Date?
    @Published var log: [String] = []

    private let client: DiscogsClient
    private let db: Database
    private let imageCache: ImageCache
    private var cancelRequested = false
    private var running = false
    private let logLock = NSLock()

    init(client: DiscogsClient, db: Database, imageCache: ImageCache) {
        self.client = client
        self.db = db
        self.imageCache = imageCache
        client.onRateLimitUpdate = { [weak self] v in
            DispatchQueue.main.async { self?.rateLimitRemaining = v }
        }
        if let u = db.getMeta("discogs_username") { username = u }
        if let d = db.getMeta("last_full_sync") {
            lastSyncDate = Double(d).flatMap { Date(timeIntervalSince1970: $0) }
        }
    }

    var isRunning: Bool { running }

    func cancel() { cancelRequested = true }

    private func note(_ s: String) {
        logLock.lock()
        log.append("[\(Date().formatted(date: .omitted, time: .standard))] \(s)")
        if log.count > 400 { log.removeFirst(log.count - 400) }
        logLock.unlock()
        if ProcessInfo.processInfo.environment["VINYLSHELF_VERBOSE"] != nil {
            FileHandle.standardError.write(Data(("  " + s + "\n").utf8))
        }
        DispatchQueue.main.async { self.objectWillChange.send() }
    }

    // MARK: - 指纹

    /// collection 列表项的字段指纹。变化即代表该条在 Discogs 上被改动过。
    static func fingerprint(_ item: DiscogsCollectionItem) -> String {
        let b = item.basic_information
        let parts: [String] = [
            String(b?.id ?? 0),
            String(b?.master_id ?? 0),
            b?.title ?? "",
            b?.thumb ?? "",
            b?.cover_image ?? "",
            String(b?.year ?? 0),
            (b?.artists ?? []).map { "\($0.id ?? 0):\($0.name ?? "")" }.joined(separator: "|"),
            (b?.labels ?? []).map { "\($0.name ?? ""):\($0.catno ?? "")" }.joined(separator: "|"),
            (b?.formats ?? []).map { "\($0.name ?? ""):\($0.qty ?? ""):\(($0.descriptions ?? []).joined(separator: ","))" }.joined(separator: "|"),
            (b?.genres ?? []).joined(separator: "|"),
            (b?.styles ?? []).joined(separator: "|"),
            b?.country ?? ""
        ]
        return StableHash.fnv1a(parts.joined(separator: "\u{1}"))
    }

    private static func detailFingerprint(_ r: Record) -> String {
        let parts = [
            String(r.discogsReleaseId), r.title, r.artist, String(r.year),
            r.country, r.released, r.notes,
            (r.genres.joined(separator: "|")),
            (r.styles.joined(separator: "|")),
            (r.labels.joined(separator: "|")),
            (r.formats.joined(separator: "|")),
            String(r.trackCount), r.coverURL,
            r.detailFetched ? "d1" : "d0"
        ]
        return StableHash.fnv1a(parts.joined(separator: "\u{1}"))
    }

    // MARK: - 主流程

    @discardableResult
    func sync(forceFullDetail: Bool = false, downloadImages: Bool = true) async -> SyncReport {
        guard !running else { return SyncReport() }
        running = true
        cancelRequested = false
        let started = Date()
        var report = SyncReport()
        defer { running = false }

        do {
            // ---- 0. 认证 ----
            setPhase(.authenticating)
            let identity = try await client.identity()
            username = identity.username ?? ""
            try db.setMeta("discogs_username", username)
            note("Token 有效，账号 \(username)")

            // ---- 1. 拉取所有 folder ----
            let folders = try await client.folders(username: username)
            note("共 \(folders.count) 个文件夹：\(folders.map { "\($0.name ?? "?")(\($0.count ?? 0))" }.joined(separator: ", "))")

            // 只同步有意义的 folder（0=All 是聚合视图，会与子文件夹重复）
            let dataFolders = folders.filter { ($0.id ?? 0) != 0 && ($0.count ?? 0) > 0 }
            let syncFolders = dataFolders.isEmpty ? folders : dataFolders

            // ---- 2. 阶段一：collection 全量分页 ----
            var online: [String: DiscogsCollectionItem] = [:]   // instanceId -> item
            var folderOfInstance: [String: Int] = [:]
            var totalExpected = 0

            for folder in syncFolders {
                let fid = folder.id ?? 0
                totalExpected += folder.count ?? 0
                var page = 1
                var pages = 1
                repeat {
                    try checkCancel()
                    let result = try await client.collectionPage(
                        username: username, folderId: fid, page: page, perPage: 100)
                    if let items = result.releases {
                        for it in items {
                            let key = String(it.instance_id ?? it.id ?? 0)
                            online[key] = it
                            folderOfInstance[key] = fid
                        }
                    }
                    if let p = result.pagination {
                        pages = p.pages ?? 1
                        setPhase(.collection(current: online.count, total: totalExpected))
                    }
                    page += 1
                } while page <= pages
            }
            note("线上共 \(online.count) 条，本地指纹比对中…")

            // ---- 3. 与本地比对 ----
            let localRecords = try db.allRecords()
            var localByInstance: [String: Record] = [:]
            for r in localRecords where r.discogsInstanceId > 0 {
                localByInstance[String(r.discogsInstanceId)] = r
            }

            var toFetch: [Record] = []
            var seenInstances = Set<String>()
            // 磁盘上持久化的「列表层指纹」，用于真正的增量判断
            let savedFingerprints = try db.allCollectionFingerprints()

            for (key, item) in online {
                try checkCancel()
                seenInstances.insert(key)
                let fp = Self.fingerprint(item)
                let existing = localByInstance[key]
                if existing == nil {
                    var rec = Self.record(from: item, folderId: folderOfInstance[key] ?? 0)
                    rec = Self.applyDetail(rec, from: nil)
                    _ = try db.upsert(rec, collectionFingerprint: fp)
                    report.added += 1
                    toFetch.append(rec)
                } else {
                    // 列表层指纹没变 → 线上这条没被编辑过，跳过（不请求详情）
                    // 指纹变了，或本地从未记录过指纹（如老版本导入）→ 拉详情刷新
                    let previous = savedFingerprints[key]
                    let changed = (previous != fp) || (!existing!.detailFetched)
                    if changed {
                        var rec = existing!
                        Self.mergeBasic(&rec, from: item, folderId: folderOfInstance[key] ?? 0)
                        _ = try db.upsert(rec, collectionFingerprint: fp)
                        report.updated += 1
                        toFetch.append(rec)
                    } else {
                        report.unchanged += 1
                    }
                }
            }

            // 线上已删除
            for (key, rec) in localByInstance where !seenInstances.contains(key) {
                try db.delete(id: rec.id)
                report.removed += 1
            }
            try db.pruneFingerprints(keeping: seenInstances)

            note("比对完成：新增 \(report.added)，变化 \(report.updated)，"
                 + "移除 \(report.removed)，无变化 \(report.unchanged)，待拉详情 \(toFetch.count)")

            // ---- 4. 阶段二：详情（仅变化/新增） ----
            if !toFetch.isEmpty {
                let total = toFetch.count
                var done = 0
                var byReleaseId: [Int: [Record]] = [:]
                for r in toFetch { byReleaseId[r.discogsReleaseId, default: []].append(r) }

                for (rid, recs) in byReleaseId.sorted(by: { $0.key < $1.key }) {
                    try checkCancel()
                    done += recs.count
                    setPhase(.detail(current: done, total: total))
                    do {
                        let data = try await client.rawReleaseJSON(id: rid)
                        guard let detail = try? JSONDecoder().decode(DiscogsRelease.self, from: data) else {
                            note("release \(rid) 详情解析失败，跳过")
                            continue
                        }
                        let raw = String(data: data, encoding: .utf8) ?? ""
                        for rec in recs {
                            var r = Self.applyDetail(rec, from: detail, rawJSON: raw)
                            r.detailFetched = true
                            _ = try db.upsert(r)
                        }
                        report.detailsFetched += 1
                    } catch let e as DiscogsError {
                        if case .invalidToken = e { throw e }
                        note("release \(rid) 详情失败：\(e.localizedDescription)（保留已有数据）")
                    }
                }
            }

            // ---- 4b. 历史遗留：过去导入但从未拉过详情的条目 ----
            let missingDetail = try db.countMissingDetail()
            if missingDetail > 0 && (forceFullDetail || report.detailsFetched > 0) {
                note("还有 \(missingDetail) 个 release 缺完整详情，继续补齐…")
                let ids = try db.releaseIdsMissingDetail(limit: 100000)
                let total = ids.count
                var done = 0
                for rid in ids {
                    try checkCancel()
                    done += 1
                    setPhase(.detail(current: done, total: total))
                    do {
                        let data = try await client.rawReleaseJSON(id: rid)
                        guard let detail = try? JSONDecoder().decode(DiscogsRelease.self, from: data) else {
                            continue
                        }
                        let raw = String(data: data, encoding: .utf8) ?? ""
                        for rec in try db.records(releaseId: rid) {
                            var r = Self.applyDetail(rec, from: detail, rawJSON: raw)
                            r.detailFetched = true
                            _ = try db.upsert(r)
                        }
                        report.detailsFetched += 1
                    } catch let e as DiscogsError {
                        if case .invalidToken = e { throw e }
                        note("release \(rid) 详情失败：\(e.localizedDescription)")
                    }
                }
            }

            // ---- 6. 封面图 ----
            // 只为本轮新增/更新的条目取图。增量同步时这个集合通常为空，
            // 不会因为「全库 299 张重试下载」把增量同步拖成几分钟。
            if downloadImages {
                let touched = toFetch
                if !touched.isEmpty {
                    setPhase(.images)
                    let n = await imageCache.warmCache(records: touched,
                                                      client: client,
                                                      limit: touched.count) { [weak self] msg in
                        self?.note(msg)
                    }
                    report.imagesCached = n
                } else {
                    note("无新增或变更，跳过封面下载")
                }
            }

            // ---- 7. 收尾 ----
            report.durationSeconds = Date().timeIntervalSince(started)
            report.rateLimitRemaining = client.rateLimitRemaining
            try db.setMeta("last_full_sync", String(Date().timeIntervalSince1970))
            try db.setMeta("last_sync_report", report.summary)
            DispatchQueue.main.async { self.lastSyncDate = Date() }
            note("✅ \(report.summary)")
            setPhase(.done(stats: report))

        } catch {
            let msg = error.localizedDescription
            note("❌ 同步失败：\(msg)")
            try? db.setMeta("last_sync_error", msg)
            setPhase(.failed(msg))
        }
        return report
    }

    private func checkCancel() throws {
        if cancelRequested {
            setPhase(.failed("已取消"))
            throw CancellationError()
        }
    }

    private func setPhase(_ p: Phase) {
        DispatchQueue.main.async { self.phase = p }
    }

    // MARK: - DTO → Record

    static func record(from item: DiscogsCollectionItem, folderId: Int) -> Record {
        let b = item.basic_information
        // ⚠️ 一律 dedupe：Discogs 会给出重复项（formats 展平、合作发行同名字多次出现）
        let artists = (b?.artists ?? []).map { $0.name ?? "" }.filter { !$0.isEmpty }.dedupe()
        let labels = (b?.labels ?? []).map { $0.name ?? "" }.filter { !$0.isEmpty }.dedupe()
        let catnos = (b?.labels ?? []).map { $0.catno ?? "" }.filter { !$0.isEmpty }.dedupe()
        let fmts = (b?.formats ?? []).flatMap { f -> [String] in
            var out: [String] = []
            if let n = f.name, !n.isEmpty { out.append(n) }
            out.append(contentsOf: f.descriptions ?? [])
            return out
        }.dedupe()
        let mainFormat = (b?.formats ?? []).first?.name ?? ""
        return Record(
            id: 0,
            discogsReleaseId: item.id ?? b?.id ?? 0,
            discogsMasterId: b?.master_id ?? 0,
            discogsInstanceId: item.instance_id ?? 0,
            discogsFolderId: folderId,
            title: b?.title ?? "",
            artist: artists.joined(separator: ", "),
            artists: artists,
            year: b?.year ?? 0,
            released: b?.released ?? "",
            country: b?.country ?? "",
            genres: b?.genres ?? [],
            styles: b?.styles ?? [],
            labels: labels,
            catnos: catnos,
            formats: fmts,
            formatQuantity: (b?.formats ?? []).first?.qty ?? "",
            mainFormat: mainFormat,
            thumbURL: b?.thumb ?? "",
            coverURL: b?.cover_image ?? "",
            trackCount: (b?.tracklist ?? []).count,
            status: b?.status ?? "",
            dataQuality: b?.data_quality ?? "",
            discogsRating: 0, discogsRatingCount: 0, haveCount: 0, wantCount: 0,
            estimatedWeight: nil, lowestPrice: nil,
            notes: b?.notes ?? "",
            discogsURI: b?.uri ?? "",
            dateAddedToDiscogs: item.date_added ?? "",
            myRating: 0, myNotes: "", tags: [], location: "", condition: "",
            dateAddedLocal: ISO8601DateFormatter().string(from: Date()),
            detailFetched: false,
            statusLocal: "owned"
        )
    }

    /// 只更新列表层字段，保留本地字段
    static func mergeBasic(_ rec: inout Record, from item: DiscogsCollectionItem, folderId: Int) {
        let b = item.basic_information
        guard let b else { return }
        rec.discogsReleaseId = item.id ?? b.id ?? rec.discogsReleaseId
        rec.discogsMasterId = b.master_id ?? rec.discogsMasterId
        rec.discogsFolderId = folderId
        rec.title = b.title ?? rec.title
        let artists = (b.artists ?? []).map { $0.name ?? "" }.filter { !$0.isEmpty }
        if !artists.isEmpty { rec.artists = artists.dedupe(); rec.artist = rec.artists.joined(separator: ", ") }
        rec.year = b.year ?? rec.year
        if let v = b.country, !v.isEmpty { rec.country = v }
        if let g = b.genres, !g.isEmpty { rec.genres = g }
        if let s = b.styles, !s.isEmpty { rec.styles = s }
        let labels = (b.labels ?? []).map { $0.name ?? "" }.filter { !$0.isEmpty }
        if !labels.isEmpty { rec.labels = labels.dedupe() }
        let catnos = (b.labels ?? []).map { $0.catno ?? "" }.filter { !$0.isEmpty }
        if !catnos.isEmpty { rec.catnos = catnos }
        let fmts = (b.formats ?? []).flatMap { f -> [String] in
            var out: [String] = []
            if let n = f.name, !n.isEmpty { out.append(n) }
            out.append(contentsOf: f.descriptions ?? [])
            return out
        }
        if !fmts.isEmpty { rec.formats = fmts.dedupe(); rec.mainFormat = (b.formats ?? []).first?.name ?? rec.mainFormat }
        rec.thumbURL = b.thumb ?? rec.thumbURL
        rec.coverURL = b.cover_image ?? rec.coverURL
        rec.discogsURI = b.uri ?? rec.discogsURI
    }

    /// 把 /releases/{id} 详情合并进记录。目标：本地留存尽可能完整的资料。
    static func applyDetail(_ rec: Record, from d: DiscogsRelease?, rawJSON: String = "") -> Record {
        var r = rec
        guard let d else { return r }
        r.discogsReleaseId = d.id ?? r.discogsReleaseId
        r.discogsMasterId = d.master_id ?? r.discogsMasterId
        r.title = d.title ?? r.title
        let artists = (d.artists ?? []).map { $0.name ?? "" }.filter { !$0.isEmpty }
        if !artists.isEmpty {
            r.artist = d.artists_sort ?? artists.joined(separator: ", ")
            r.artists = artists.dedupe()
        }
        r.year = d.year ?? r.year
        r.released = d.released ?? r.released
        r.releasedFormatted = d.released_formatted ?? r.releasedFormatted
        if let c = d.country, !c.isEmpty { r.country = c }        // ← collection 端点缺的关键字段
        if let n = d.notes, !n.isEmpty { r.notes = n }
        if let g = d.genres, !g.isEmpty { r.genres = g }
        if let s = d.styles, !s.isEmpty { r.styles = s }
        let labels = (d.labels ?? []).map { $0.name ?? "" }.filter { !$0.isEmpty }
        if !labels.isEmpty { r.labels = labels.dedupe() }
        let catnos = (d.labels ?? []).map { $0.catno ?? "" }.filter { !$0.isEmpty }
        if !catnos.isEmpty { r.catnos = catnos }
        let fmts = (d.formats ?? []).flatMap { f -> [String] in
            var out: [String] = []
            if let n = f.name, !n.isEmpty { out.append(n) }
            out.append(contentsOf: f.descriptions ?? [])
            return out
        }
        if !fmts.isEmpty { r.formats = fmts.dedupe() }
        r.mainFormat = (d.formats ?? []).first?.name ?? r.mainFormat
        r.formatQuantity = d.format_quantity?.value ?? r.formatQuantity
        r.status = d.status ?? r.status
        r.dataQuality = d.data_quality ?? r.dataQuality
        r.discogsRating = d.community?.rating?.average ?? r.discogsRating
        r.discogsRatingCount = d.community?.rating?.count ?? r.discogsRatingCount
        r.haveCount = d.community?.have ?? r.haveCount
        r.wantCount = d.community?.want ?? r.wantCount
        r.estimatedWeight = d.estimated_weight
        r.lowestPrice = d.lowest_price
        r.discogsURI = d.uri ?? r.discogsURI
        if let dc = d.date_changed { r.dateChangedOnDiscogs = dc }

        // ---- 富详情：曲目表 ----
        if let tl = d.tracklist, !tl.isEmpty {
            r.tracklist = tl.map { t in
                Track(
                    position: t.position ?? "",
                    type: t.type_ ?? "track",
                    title: t.title ?? "",
                    duration: t.duration ?? "",
                    credits: (t.extraartists ?? []).map { TrackCredit(role: $0.role ?? "其他", name: $0.name ?? "") },
                    isHeading: (t.type_ ?? "track") == "heading"
                )
            }
            r.trackCount = r.tracklist.filter { !$0.isHeading }.count
        }

        // ---- 富详情：制作人员 ----
        if let ea = d.extraartists, !ea.isEmpty {
            r.credits = ea.map {
                Credit(name: $0.name ?? "", anv: $0.anv ?? "", role: $0.role ?? "",
                      tracks: $0.tracks ?? "", join: $0.join ?? "")
            }
        }

        // ---- 富详情：参与公司（录于/版权/压片厂）----
        if let cs = d.companies, !cs.isEmpty {
            r.companies = cs.map {
                Company(name: $0.name ?? "", catno: $0.catno ?? "",
                        entityTypeName: $0.entity_type_name ?? "")
            }
        }

        // ---- 富详情：编号体系（Barcode / Matrix / Label Code）----
        if let ids = d.identifiers, !ids.isEmpty {
            r.identifiers = ids.map {
                ReleaseIdentifier(type: $0.type ?? "", value: $0.value ?? "",
                                  description: $0.description ?? "")
            }
        }

        // ---- 富详情：系列 ----
        if let se = d.series, !se.isEmpty {
            r.series = se.map { $0.name ?? "" }
        }

        // ---- 富详情：全部图集 ----
        if let imgs = d.images, !imgs.isEmpty {
            r.gallery = imgs.compactMap { img in
                guard let u = img.uri, !u.isEmpty else { return nil }
                return CoverImage(uri: u, uri150: img.uri150 ?? "", type: img.type ?? "",
                                  width: img.width ?? 0, height: img.height ?? 0)
            }
            // 主图优先
            if let primary = r.gallery.first(where: { $0.type == "primary" }) ?? r.gallery.first {
                r.coverURL = primary.uri
            }
        }
        if let t = d.thumb, !t.isEmpty, r.thumbURL.isEmpty { r.thumbURL = t }

        if !rawJSON.isEmpty { r.rawJSON = rawJSON }
        r.detailFetched = true
        return r
    }

    /// 拉取并保存一个 release 的完整详情（含原始 JSON 留存）
    func enrich(records: [Record]) async -> Bool {
        guard let rid = records.first?.discogsReleaseId, rid > 0 else { return false }
        guard let data = try? await client.rawReleaseJSON(id: rid),
              let detail = try? JSONDecoder().decode(DiscogsRelease.self, from: data) else {
            return false
        }
        for rec in records {
            var r = Self.applyDetail(rec, from: detail, rawJSON: String(data: data, encoding: .utf8) ?? "")
            r.detailFetched = true
            _ = try? db.upsert(r)
        }
        return true
    }
}
