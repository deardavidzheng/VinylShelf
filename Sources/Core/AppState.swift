import Foundation
import SwiftUI

/// 应用状态中枢：持有库、同步引擎、筛选条件
@MainActor
final class AppState: ObservableObject {
    let db: Database!
    let client: DiscogsClient
    let sync: SyncEngine
    let push: PushEngine
    let imageCache: ImageCache

    @Published var records: [Record] = []
    @Published var filter = FacetFilter()
    @Published var selectedId: Int64?
    @Published var searchText = ""
    @Published var viewMode: ViewMode = .grid
    @Published var sortOrder: SortOrder = .artistAscending
    @Published var facetCounts: [String: [String: Int]] = [:]
    @Published var isTokenConfigured = false
    @Published var dbError: String?
    @Published var statusMessage = ""
    @Published var isSearching = false
    @Published var searchResults: [DiscogsSearchResult] = []
    @Published var searchQuery = ""
    @Published var searchType: SearchType = .release
    @Published var searchSort: SearchSort = .relevance
    @Published var searchPage = 1
    @Published var searchPageCount = 1
    @Published var searchTotal = 0
    /// 搜索结果每页条数。Discogs 上限 100
    let searchPageSize = 50
    /// 正在添加的 release id，用于行内转圈而不是整窗转圈
    @Published var addingReleaseId: Int?

    enum ViewMode: String, CaseIterable {
        case grid, list
        var icon: String { self == .grid ? "square.grid.2x2" : "list.bullet" }
    }

    enum SortOrder: String, CaseIterable {
        case artistAscending, artistDescending
        case yearAscending, yearDescending
        case titleAscending, recentlyAdded

        var label: String {
            switch self {
            case .artistAscending: return "艺人 A→Z"
            case .artistDescending: return "艺人 Z→A"
            case .yearAscending: return "年份 旧→新"
            case .yearDescending: return "年份 新→旧"
            case .titleAscending: return "标题 A→Z"
            case .recentlyAdded: return "最近加入"
            }
        }
    }

    init() {
        do {
            db = try Database(url: AppPaths.database)
        } catch {
            fatalError("无法打开数据库：\(error)")
        }
        client = .shared          // 视图层（CachedCover）也要用同一个带 token 的实例
        imageCache = ImageCache(db: db)
        sync = SyncEngine(client: client, db: db, imageCache: imageCache)
        push = PushEngine(client: client, db: db, imageCache: imageCache, sync: sync)
        reload()
        applyStartupPreset()
        // ⚠️ Keychain 的 ACL 绑定写入者。若这条记录是别的二进制写的，
        // 每次读都会弹系统密码框。只有在本 App 自己写过（有标记文件）时才读。
        // App 自己写的项，App 自己读不需要授权。
        isTokenConfigured = KeychainItemExists()
        if isTokenConfigured {
            Task.detached(priority: .userInitiated) { [weak self] in
                let token = Keychain.get(account: "discogs_token")
                await MainActor.run {
                    guard let self, !self.client.hasToken else { return }
                    self.client.setToken(token)
                    self.isTokenConfigured = token != nil
                }
            }
        }
    }

    // MARK: - 数据

    /// 启动时预置筛选条件，供复现特定 UI 状态。
    ///
    /// 用法：`VINYLSHELF_PRESET="genre=Electronic" VinylShelf`（`launchctl setenv` 亦可）
    ///
    /// 之所以需要它：本机没有辅助功能权限，没法注入真实鼠标点击，
    /// 而「选中某个标签后其他标签是否还在」恰恰是必须点一下才出现的状态。
    /// 没有这个开关就只能改代码重来一遍才能截到图。
    /// 正常启动不带该环境变量，不影响用户。
    private func applyStartupPreset() {
        if let raw = ProcessInfo.processInfo.environment["VINYLSHELF_PRESET"], !raw.isEmpty {
            let parts = raw.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, let dim = FacetDimension(rawValue: parts[0]) else {
                FileHandle.standardError.write(Data("VINYLSHELF_PRESET 格式应为 维度=值\n".utf8))
                return
            }
            filter.toggle(dimension: dim, value: parts[1])
            let line = "已预置筛选 \(dim.displayName) = \(parts[1])，命中 \(filteredCount)/\(totalCount)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        applySelectionPreset()
    }

    /// 调试用启动预置：预选中一张唱片，让右侧详情栏直接渲染。
    ///
    /// 用法：`VINYLSHELF_SELECT=<Discogs release id>`。
    ///
    /// 为什么要它：详情栏是「点一张唱片才出现」的三栏最右栏，
    /// 而本机没有辅助功能权限、注入不了真实点击；没有这个开关，
    /// 要截出富详情（曲目/人员/公司/编号/图集）只能改产品代码，
    /// 那会让截图失真——插一段临时代码再删掉，截出来的图和用户实际用到的不是同一个东西。
    /// 正常启动不带该环境变量，选中态仍由点击决定。
    private func applySelectionPreset() {
        guard let raw = ProcessInfo.processInfo.environment["VINYLSHELF_SELECT"],
              let releaseId = Int(raw.trimmingCharacters(in: .whitespaces)),
              let hit = records.first(where: { $0.discogsReleaseId == releaseId })
        else { return }
        selectedId = hit.id
        FileHandle.standardError.write(Data(
            "已预选中 release \(releaseId)：\(hit.artist) — \(hit.title)\n".utf8))
    }

    func reload() {
        do {
            records = try db.allRecords()
            recomputeFacets()
        } catch {
            dbError = error.localizedDescription
        }
    }

    func recomputeFacets() {
        do {
            // ⚠️ 覆盖「全部」维度，不能只挑几个。
            // 曾经硬编码 [genre, style, decade, country, label, format]，
            // 结果艺人（428 个取值）、品相、收藏状态、文件夹、自定义标签
            // 这 5 个维度在侧栏里全是空白——数据在库里，只是没去查。
            //
            // 同时刻意「不」做 drill-down：facet 计数恒为全库口径。
            // 若按当前筛选子集统计，选中「Electronic」后整个标签宇宙会塌缩成
            // 该子集里实际出现过的值——表现就是「选中一个标签后其他标签不见了」，
            // 看起来像该维度不支持多选。标签列表必须恒定不变，筛选只影响中间栏结果。
            facetCounts = try db.facetCounts(dimensions: FacetDimension.allCases, restrictIds: nil)
        } catch {
            dbError = error.localizedDescription
        }
    }

    // MARK: - 检索

    func filteredRecords() -> [Record] {
        let f = filter
        let text = (f.freeText.isEmpty ? searchText : f.freeText)
            .trimmed.lowercased()

        var out = records.filter { r in
            // 自由文本：艺人/标题/厂牌/目录号/风格
            if !text.isEmpty {
                let hay = ([r.artist, r.title] + r.labels + r.styles + r.genres + r.catnos)
                    .joined(separator: " ").lowercased()
                if !hay.contains(text) { return false }
            }
            // 年份区间
            if let yf = f.yearFrom, r.year > 0, r.year < yf { return false }
            if let yt = f.yearTo, r.year > 0, r.year > yt { return false }
            if let yf = f.yearFrom, r.year == 0 { return false }
            if let yt = f.yearTo, r.year == 0 { return false }
            // 我的评分
            if f.minRating > 0, r.myRating < f.minRating { return false }

            // 各维度
            for (dimRaw, selected) in f.selections where !selected.isEmpty {
                guard let dim = FacetDimension(rawValue: dimRaw) else { continue }
                let values = Set(dim.values(of: r))
                // 维度内多选 = 或（并集）：命中任一选中值即通过
                if selected.isDisjoint(with: values) { return false }
            }
            return true
        }
        out = sort(out)
        return out
    }

    private func sort(_ input: [Record]) -> [Record] {
        switch sortOrder {
        case .artistAscending:
            return input.sorted {
                let a = $0.artist.lowercased(), b = $1.artist.lowercased()
                if a != b { return a < b }
                return $0.year < $1.year
            }
        case .artistDescending:
            return input.sorted {
                let a = $0.artist.lowercased(), b = $1.artist.lowercased()
                if a != b { return a > b }
                return $0.year < $1.year
            }
        case .yearAscending:
            return input.sorted { ($0.year == 0 ? 9999 : $0.year) < ($1.year == 0 ? 9999 : $1.year) }
        case .yearDescending:
            return input.sorted { ($0.year == 0 ? -1 : $0.year) > ($1.year == 0 ? -1 : $1.year) }
        case .titleAscending:
            return input.sorted { $0.title.lowercased() < $1.title.lowercased() }
        case .recentlyAdded:
            return input.sorted { $0.id > $1.id }
        }
    }

    var selectedRecord: Record? {
        guard let id = selectedId else { return nil }
        return records.first { $0.id == id }
    }

    // MARK: - 统计

    var totalCount: Int { records.count }
    var filteredCount: Int { filteredRecords().count }

    /// 全库统计面板
    struct Overview {
        var total = 0
        var byDecade: [(String, Int)] = []
        var byCountry: [(String, Int)] = []
        var byGenre: [(String, Int)] = []
        var byStyle: [(String, Int)] = []
        var byFormat: [(String, Int)] = []
        var byLabel: [(String, Int)] = []
        var yearRange: (Int, Int) = (0, 0)
        var withCountry = 0
        var missingDetail = 0
        var totalLowestPrice: Double = 0
        var duplicateInstances = 0
    }

    var overview: Overview {
        var o = Overview()
        o.total = records.count
        o.missingDetail = records.filter { !$0.detailFetched }.count
        o.withCountry = records.filter { !$0.country.isEmpty }.count
        let ids = Dictionary(grouping: records, by: \.discogsReleaseId)
        o.duplicateInstances = ids.values.filter { $0.count > 1 }.count
        o.totalLowestPrice = records.compactMap(\.lowestPrice).reduce(0, +)

        func tally(_ keyPath: (Record) -> [String]) -> [(String, Int)] {
            var c: [String: Int] = [:]
            for r in records { for v in keyPath(r) where !v.isEmpty { c[v, default: 0] += 1 } }
            return c.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
        }
        o.byDecade = tally { $0.year > 0 ? ["\($0.decade)s"] : [] }
        o.byCountry = tally { [$0.country] }
        o.byGenre = tally { $0.genres }
        o.byStyle = tally { $0.styles }
        o.byFormat = tally { $0.formats }
        o.byLabel = tally { $0.labels }

        let years = records.map(\.year).filter { $0 > 0 }
        o.yearRange = (years.min() ?? 0, years.max() ?? 0)
        return o
    }

    // MARK: - 认证

    func saveToken(_ token: String) {
        Keychain.set(token, account: "discogs_token")
        client.setToken(token)
        isTokenConfigured = client.hasToken
        if client.hasToken {
            try? "1".write(to: AppPaths.tokenMarker, atomically: true, encoding: .utf8)
        }
        objectWillChange.send()
    }

    func clearToken() {
        Keychain.delete(account: "discogs_token")
        client.setToken(nil)
        isTokenConfigured = false
        try? FileManager.default.removeItem(at: AppPaths.tokenMarker)
    }

    // MARK: - 本地字段

    func updateLocal(_ record: Record,
                     rating: Int? = nil, notes: String? = nil,
                     tags: [String]? = nil, location: String? = nil,
                     condition: String? = nil, statusLocal: String? = nil) {
        do {
            try db.updateLocalFields(id: record.id, myRating: rating, myNotes: notes,
                                     tags: tags, location: location,
                                     condition: condition, statusLocal: statusLocal)
            reload()
        } catch {
            dbError = error.localizedDescription
        }
    }

    func deleteRecord(_ record: Record) {
        do {
            try db.delete(id: record.id)
            if selectedId == record.id { selectedId = nil }
            reload()
        } catch {
            dbError = error.localizedDescription
        }
    }

    /// 从 Discogs 拉取单条的最新完整详情
    func refreshOne(_ record: Record) async {
        guard record.discogsReleaseId > 0 else { return }
        statusMessage = "正在拉取 \(record.title) 的完整资料…"
        let ok = await sync.enrich(records: [record])
        reload()
        statusMessage = ok ? "已更新 \(record.title)" : "拉取失败"
    }

    // MARK: - 搜索添加

    /// Discogs 搜索的排序方式（对应 API 的 `sort` 参数）
    enum SearchSort: String, CaseIterable, Identifiable {
        case relevance = "", newest = "newest", oldest = "oldest"
        case rating = "rating", titleAsc = "title_asc", artistAsc = "artists_asc"
        var id: String { rawValue }
        var label: String {
            switch self {
            case .relevance: return "相关度"
            case .newest: return "最新"
            case .oldest: return "最早"
            case .rating: return "评分"
            case .titleAsc: return "标题 A→Z"
            case .artistAsc: return "艺人 A→Z"
            }
        }
    }

    /// 搜索范围
    enum SearchType: String, CaseIterable, Identifiable {
        case release, master
        var id: String { rawValue }
        var label: String { self == .release ? "单曲发行版 Release" : "专辑 Master" }
    }

    /// 搜索。只保留最近一次查询的结果——新的搜索会把上一次的追加结果清掉。
    func searchDiscogs(_ query: String,
                       page: Int = 1,
                       type: SearchType = .release,
                       sort: SearchSort = .relevance) async {
        let q = query.trimmed
        guard !q.isEmpty else {
            searchResults = []
            searchTotal = 0
            searchPage = 1
            searchPageCount = 1
            return
        }
        isSearching = true
        defer { isSearching = false }
        do {
            let res = try await client.search(query: q, type: type.rawValue,
                                              sort: sort.rawValue.nilIfEmpty,
                                              page: page, perPage: searchPageSize)
            searchResults = res.results ?? []
            searchPage = res.pagination?.page ?? page
            searchPageCount = max(1, res.pagination?.pages ?? 1)
            searchTotal = res.pagination?.items ?? searchResults.count
            // 校验一下真的解码出东西了，而不是又静默变成 0 条
            if searchResults.isEmpty && searchTotal > 0 {
                statusMessage = "Discogs 返回了 \(searchTotal) 条结果，但没有一条能解析（字段格式可能又变了）"
            }
            // 预取缩略图：否则要等每行视图自己触发下载，整列会空十几秒
            let thumbs = searchResults.compactMap { $0.thumb?.nilIfEmpty }
            if !thumbs.isEmpty {
                let cache = imageCache
                let api = client
                Task.detached(priority: .utility) {
                    _ = await cache.prefetch(thumbs, client: api)
                }
            }
        } catch {
            searchResults = []
            searchPage = 1
            searchPageCount = 1
            searchTotal = 0
            // 把原始错误也带上——之前"网页能搜、App 报错"就是被这条吞掉了细节
            statusMessage = "搜索失败：\(error.localizedDescription)"
        }
    }

    /// 翻页
    func searchPage(_ page: Int) async {
        await searchDiscogs(searchQuery, page: page,
                            type: searchType, sort: searchSort)
    }

    /// 本地已有的 release id，用于在搜索结果里标「已在本地」并禁用重复添加
    var localReleaseIds: Set<Int> {
        var s = Set<Int>()
        s.reserveCapacity(records.count)
        for r in records where r.discogsReleaseId > 0 { s.insert(r.discogsReleaseId) }
        return s
    }

    /// 某条搜索结果是否已在本地库
    func isInLibrary(_ result: DiscogsSearchResult) -> Bool {
        guard let id = result.id else { return false }
        return localReleaseIds.contains(id)
    }

    /// 从 Discogs 搜索结果添加到本地。
    /// 流程：插入占位记录 → 拉完整详情（曲目/人员/公司/编号/图集）→ 下载全部图片到本地。
    /// - Parameters:
    ///   - downloadImages: 是否下载主封面与图集
    ///   - alsoToDiscogs: 同时把这张唱片加入你的 Discogs 收藏
    ///   - toWantlist: 同时加入 Discogs 想读单
    /// - Returns: 本地是否新增成功（供 UI 决定打勾与禁用）
    @discardableResult
    func addFromDiscogs(_ result: DiscogsSearchResult,
                         downloadImages: Bool = true,
                         alsoToDiscogs: Bool = false,
                         toWantlist: Bool = false) async -> Bool {
        guard let rid = result.id else {
            statusMessage = "该搜索结果没有 release id"
            return false
        }
        // 已经导入过就不再重复添加，但仍可能需要补推 Discogs
        if let existing = try? db.records(releaseId: rid).first, existing != nil {
            let msg = await pushExisting(rid, alsoToDiscogs: alsoToDiscogs, toWantlist: toWantlist)
            statusMessage = msg.isEmpty
                ? "「\(result.title ?? "")」已在本地库中"
                : "已在本地库中 · \(msg)"
            return false
        }

        addingReleaseId = rid
        defer { addingReleaseId = nil }
        statusMessage = "正在获取 \(result.title ?? "") 的完整资料…"
        // 先建占位记录（instanceId = 0 → 纯本地新增，尚未进入 Discogs 收藏）
        let rec = Record.placeholder(from: result, statusLocal: "owned")
        do {
            _ = try db.upsert(rec)
        } catch {
            statusMessage = "添加失败：\(error.localizedDescription)"
            return false
        }

        // 拉完整详情
        var fetched = false
        if let f = try? db.records(releaseId: rid).first {
            fetched = await sync.enrich(records: [f])
        }
        if !fetched {
            statusMessage = "已加入，但 Discogs 详情获取失败（保留搜索结果信息）"
            reload()
            return true
        }

        // 下载全部图片（主封面 + 图集）
        var saved = 0
        if downloadImages, let f = try? db.records(releaseId: rid).first {
            statusMessage = "正在下载《\(f.title)》的图片…"
            for img in [f.coverURL] + f.gallery.map(\.uri) {
                if img.isEmpty { continue }
                if await imageCache.fetchOne(img, client: client) { saved += 1 }
            }
        }

        // 可选：同时加入 Discogs 收藏 / 想读单
        var pushed = ""
        if alsoToDiscogs || toWantlist {
            pushed = await pushExisting(rid, alsoToDiscogs: alsoToDiscogs, toWantlist: toWantlist)
        }

        reload()
        var msg = "已加入：\(result.title ?? "")（图片 \(saved) 张）"
        if !pushed.isEmpty { msg += "　" + pushed }
        statusMessage = msg
        return true
    }

    /// 把已存在的本地记录补推到 Discogs（收藏 / 想读单）
    private func pushExisting(_ releaseId: Int, alsoToDiscogs: Bool, toWantlist: Bool) async -> String {
        if push.username.isEmpty { await push.prepare(username: await resolveUsername()) }
        var parts: [String] = []
        if alsoToDiscogs {
            let m = await push.addToDiscogsCollection(releaseId: releaseId)
            if !m.isEmpty { parts.append(m) }
        }
        if toWantlist {
            let m = await push.addToWantlist(releaseId: releaseId)
            if !m.isEmpty { parts.append(m) }
        }
        return parts.joined(separator: "　")
    }

    /// 当前 Discogs 用户名（带缓存）
    private var cachedUsername = ""
    private func resolveUsername() async -> String {
        if !cachedUsername.isEmpty { return cachedUsername }
        if let id = try? await client.identity(), let u = id.username, !u.isEmpty {
            cachedUsername = u
            return u
        }
        return sync.username
    }

    // MARK: - 本地 → Discogs 写回

    @Published var pushProgress = ""
    @Published var isPushing = false

    /// 待推送数量：本地新增、尚未进入 Discogs 收藏的记录
    var pendingPushCount: Int { records.filter(\.isPendingPush).count }

    /// 把所有待推送记录写入 Discogs 收藏
    func pushPendingToDiscogs(max: Int = 200) async {
        guard !isPushing else { return }
        isPushing = true
        defer { isPushing = false }
        let r = await push.pushAllPending(max: max) { [weak self] msg in
            Task { @MainActor in self?.pushProgress = msg }
        }
        statusMessage = "推送完成：成功 \(r.ok)，失败 \(r.failed)"
        reload()
    }

    /// 导入 Discogs 想读单
    func importDiscogsWantlist(downloadImages: Bool = true) async {
        guard !isPushing else { return }
        isPushing = true
        defer { isPushing = false }
        let result = await push.importWantlist(downloadImages: downloadImages) { [weak self] msg in
            Task { @MainActor in self?.pushProgress = msg }
        }
        statusMessage = result.message
        reload()
    }

    /// 从详情视图懒加载封面
    func ensureCover(for record: Record) async {
        guard !record.coverURL.isEmpty else { return }
        guard imageCache.image(for: record.coverURL) == nil else { return }
        _ = await imageCache.fetchOne(record.coverURL, client: client)
    }

    /// 主动下载全部封面
    @Published var coverTaskRunning = false
    @Published var coverProgress = ""

    func downloadAllCovers() async {
        guard !coverTaskRunning else { return }
        coverTaskRunning = true
        coverProgress = "准备中…"
        defer { coverTaskRunning = false }
        let n = await imageCache.warmCache(records: records, client: client, limit: 1000) { [weak self] msg in
            Task { @MainActor in self?.coverProgress = msg }
        }
        coverProgress = "完成：\(n)/\(records.count)"
        reload()
    }

    // MARK: - 导出

    /// 导出 CSV
    func exportCSV() {
        let rows = filteredRecords()
        var out = "标题,艺人,年份,国家,流派,风格,厂牌,目录号,规格,曲数,Discogs评分,持有数,想要数,最低价,我的评分,品相,存放位置,标签,备注,Discogs链接\n"
        func esc(_ s: String) -> String {
            let v = s.replacingOccurrences(of: "\"", with: "\"\"")
            return v.contains(",") || v.contains("\"") || v.contains("\n") ? "\"\(v)\"" : v
        }
        for r in rows {
            let fields = [
                r.title, r.artist, String(r.year), r.country,
                r.genres.joined(separator: " / "), r.styles.joined(separator: " / "),
                r.labels.joined(separator: " / "), r.catnos.joined(separator: " / "),
                r.formats.joined(separator: " / "), String(r.trackCount),
                r.discogsRating > 0 ? String(format: "%.2f", r.discogsRating) : "",
                String(r.haveCount), String(r.wantCount),
                r.lowestPrice.map { String(format: "%.2f", $0) } ?? "",
                String(r.myRating), r.condition, r.location,
                r.tags.joined(separator: " / "), r.myNotes,
                r.discogsURI.isEmpty ? "" : "https://www.discogs.com" + r.discogsURI
            ]
            out += fields.map(esc).joined(separator: ",") + "\n"
        }
        let url = AppPaths.exportDir.appendingPathComponent(
            "vinylshelf-\(Date().formatted(.iso8601.year().month().day()))-\(rows.count).csv")
        try? out.write(to: url, atomically: true, encoding: .utf8)
        statusMessage = "已导出 \(rows.count) 条到 \(url.path)"
    }
}
