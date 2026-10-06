import Foundation

// MARK: - Discogs 原始 DTO（严格对齐实测 JSON 字段名）

/// Discogs 同一字段在不同端点/版本可能是数字或字符串（如 format_quantity）
/// —— 用这个类型兜住，避免整条 release 因单个字段类型不符而解析失败。
struct LooseInt: Codable {
    let value: String
    var intValue: Int? { Int(value) }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) { value = String(i) }
        else if let d = try? c.decode(Double.self) { value = String(Int(d)) }
        else if let s = try? c.decode(String.self) { value = s }
        else { value = "" }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        if let i = intValue { try c.encode(i) } else { try c.encode(value) }
    }
}

/// collection 端点返回的 basic_information 子对象
struct DiscogsBasicInfo: Codable {
    var id: Int?
    var master_id: Int?
    var master_url: String?
    var resource_url: String?
    var thumb: String?
    var cover_image: String?
    var title: String?
    var year: Int?
    var released: String?
    var country: String?            // ⚠️ collection 端点实测 0/299 有值，必须靠 /releases/{id} 补
    var notes: String?
    var released_formatted: String?
    var artists: [DiscogsNamed]?
    var labels: [DiscogsLabel]?
    var formats: [DiscogsFormat]?
    var genres: [String]?
    var styles: [String]?
    var identifiers: [DiscogsIdentifier]?
    var companies: [DiscogsCompany]?
    var tracklist: [DiscogsTrack]?
    var extraartists: [DiscogsExtraArtist]?
    var series: [DiscogsNamed]?
    var status: String?
    var data_quality: String?
    var uri: String?
}

struct DiscogsNamed: Codable {
    var id: Int?
    var name: String?
    var anv: String?
    var `join`: String?
    var role: String?
    var tracks: String?
    var resource_url: String?
}

struct DiscogsLabel: Codable {
    var id: Int?
    var name: String?
    var catno: String?
    var entity_type: String?
    var entity_type_name: String?
    var resource_url: String?
}

struct DiscogsFormat: Codable {
    var name: String?
    var qty: String?
    var text: String?
    var descriptions: [String]?
}

struct DiscogsIdentifier: Codable {
    var type: String?
    var value: String?
    var description: String?
}

struct DiscogsCompany: Codable {
    var id: Int?
    var name: String?
    var catno: String?
    var entity_type_name: String?
}

struct DiscogsTrack: Codable {
    var position: String?
    var type_: String?
    var title: String?
    var duration: String?
    var extraartists: [DiscogsExtraArtist]?
}

struct DiscogsExtraArtist: Codable {
    var id: Int?
    var name: String?
    var anv: String?
    var `join`: String?
    var role: String?
    var tracks: String?
}

struct DiscogsImage: Codable {
    var type: String?
    var uri: String?
    var uri150: String?
    var width: Int?
    var height: Int?        // 实测为数字
}

struct DiscogsCommunity: Codable {
    var have: Int?
    var want: Int?
    var rating: DiscogsRating?
    var submitter: DiscogsSubmitter?
}

struct DiscogsRating: Codable {
    var count: Int?
    var average: Double?
}

struct DiscogsSubmitter: Codable {
    var username: String?
    var resource_url: String?
}

/// collection 端点单条记录（外层 + instance_id + rating）
struct DiscogsCollectionItem: Codable {
    var basic_information: DiscogsBasicInfo?
    var date_added: String?
    var folder_id: Int?
    var id: Int?
    var instance_id: Int?
    var rating: Int?
}

struct DiscogsCollectionPage: Codable {
    var pagination: DiscogsPagination?
    var releases: [DiscogsCollectionItem]?
}

struct DiscogsPagination: Codable {
    var page: Int?
    var pages: Int?
    var per_page: Int?
    var items: Int?
    var urls: [String: String]?
}

struct DiscogsFolder: Codable {
    var id: Int?
    var name: String?
    var count: Int?
    var resource_url: String?
}

struct DiscogsFolderList: Codable {
    var folders: [DiscogsFolder]?
}

/// /releases/{id} 完整详情
struct DiscogsRelease: Codable {
    var id: Int?
    var master_id: Int?
    var master_url: String?
    var title: String?
    var released: String?
    var released_formatted: String?
    var country: String?
    var notes: String?
    var year: Int?
    var artists: [DiscogsNamed]?
    var artists_sort: String?
    var labels: [DiscogsLabel]?
    var series: [DiscogsNamed]?
    var companies: [DiscogsCompany]?
    var formats: [DiscogsFormat]?
    var format_quantity: LooseInt?
    var data_quality: String?
    var status: String?
    var genres: [String]?
    var styles: [String]?
    var tracklist: [DiscogsTrack]?
    var extraartists: [DiscogsExtraArtist]?
    var identifiers: [DiscogsIdentifier]?
    var images: [DiscogsImage]?
    var thumb: String?
    var uri: String?
    var resource_url: String?
    var community: DiscogsCommunity?
    var estimated_weight: Int?
    var lowest_price: Double?
    var num_for_sale: Int?
    var date_added: String?
    var date_changed: String?
}

struct DiscogsSearchResult: Codable {
    var id: Int?
    var type: String?
    var title: String?
    var uri: String?
    var resource_url: String?
    var master_id: Int?
    var master_url: String?
    var thumb: String?
    var cover_image: String?
    var year: Int?
    var country: String?
    var label: [String]?
    var catno: String?
    var format: [String]?
    var genre: [String]?
    var style: [String]?
    var barcode: String?
    var user_data: DiscogsUserData?
    /// 搜索结果自带持有/想要人数（`{"want":976,"have":4532}`），判断稀有度很有用
    var community: DiscogsCommunity?
    var resourceURL: String? { resource_url }

    enum CodingKeys: String, CodingKey {
        case id, type, title, uri, resource_url, master_id, master_url, thumb, cover_image
        case year, country, label, catno, format, genre, style, barcode, user_data, community
    }

    /// 成员初始化器。
    /// 必须手写：一旦声明了 `init(from decoder:)`，编译器就不再合成 memberwise init，
    /// 而测试与本地构造（占位记录）都需要它。所有参数都有默认值。
    init(id: Int? = nil, type: String? = nil, title: String? = nil,
         uri: String? = nil, resource_url: String? = nil, master_id: Int? = nil,
         master_url: String? = nil, thumb: String? = nil, cover_image: String? = nil,
         year: Int? = nil, country: String? = nil, label: [String]? = nil,
         catno: String? = nil, format: [String]? = nil, genre: [String]? = nil,
         style: [String]? = nil, barcode: String? = nil,
         user_data: DiscogsUserData? = nil, community: DiscogsCommunity? = nil) {
        self.id = id; self.type = type; self.title = title; self.uri = uri
        self.resource_url = resource_url; self.master_id = master_id
        self.master_url = master_url; self.thumb = thumb; self.cover_image = cover_image
        self.year = year; self.country = country; self.label = label; self.catno = catno
        self.format = format; self.genre = genre; self.style = style; self.barcode = barcode
        self.user_data = user_data; self.community = community
    }

    /// 逐字段**独立**容错解码。
    ///
    /// 为什么必须这么做：`/database/search` 的字段类型会飘忽——
    /// 实测 `year` 在这个端点返回的是字符串 `"2023"`（而 `/releases/{id}` 返回数字），
    /// 声明成 `Int?` 时 `JSONDecoder` 会在**第一条结果**就抛 typeMismatch，
    /// 整页 50 条结果全变成 0 条，于是「网页能搜，App 却报数据解析失败」。
    ///
    /// 这里每个字段各用 `try?` 单独兜住：单个字段异常最多让该字段显示为空，
    /// 不会连累整页结果。`year` 额外用 `LooseInt` 兼容字符串/数字/null 三种形态。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v<T: Decodable>(_ key: CodingKeys, _ type: T.Type = T.self) -> T? {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil)
        }
        id = v(.id, Int.self)
        type = v(.type, String.self)
        title = v(.title, String.self)
        uri = v(.uri, String.self)
        resource_url = v(.resource_url, String.self)
        master_id = v(.master_id, Int.self)
        master_url = v(.master_url, String.self)
        thumb = v(.thumb, String.self)
        cover_image = v(.cover_image, String.self)
        year = v(.year, LooseInt.self)?.intValue
        country = v(.country, String.self)
        label = v(.label, [String].self)
        catno = v(.catno, String.self)
        format = v(.format, [String].self)
        genre = v(.genre, [String].self)
        style = v(.style, [String].self)
        barcode = v(.barcode, String.self)
        user_data = v(.user_data, DiscogsUserData.self)
        community = v(.community, DiscogsCommunity.self)
    }
}

struct DiscogsUserData: Codable {
    var in_wantlist: Bool?
    var in_collection: Bool?
}

struct DiscogsSearchPage: Codable {
    var pagination: DiscogsPagination?
    var results: [DiscogsSearchResult]?
}

/// GET /users/{u}/wantlist —— 条目结构与搜索结果一致，直接复用 DTO
struct DiscogsWantlistPage: Codable {
    var pagination: DiscogsPagination?
    var wants: [DiscogsSearchResult]?
}

struct DiscogsIdentity: Codable {
    var id: Int?
    var username: String?
    var resource_url: String?
    var consumer_name: String?
}

// MARK: - 本地领域模型

/// 曲目内的人员署名
struct TrackCredit: Hashable, Codable {
    var role: String
    var name: String
}

/// 曲目
struct Track: Hashable, Codable {
    var position: String
    var type: String
    var title: String
    var duration: String
    /// 该曲的制作人员
    var credits: [TrackCredit]
    var isHeading: Bool

    init(position: String, type: String, title: String, duration: String,
         credits: [TrackCredit], isHeading: Bool = false) {
        self.position = position
        self.type = type
        self.title = title
        self.duration = duration
        self.credits = credits
        self.isHeading = isHeading
    }

    var displayTitle: String { isHeading ? title : "\(position)  \(title)" }
    var durationDisplay: String { duration.nilIfEmpty ?? "" }
}

/// 制作人员 / 参演人员（extraartists）
struct Credit: Hashable, Codable {
    var name: String
    var anv: String
    var role: String
    var tracks: String
    var join: String
    var displayName: String { anv.nilIfEmpty ?? name }
    var tracksDisplay: String { tracks.nilIfEmpty ?? "" }
}

/// 参与公司（录于 / 版权 / 母版 / 压片厂）
struct Company: Hashable, Codable {
    var name: String
    var catno: String
    var entityTypeName: String
}

/// 编号体系（Barcode / Matrix / Label Code / Catalog …）
struct ReleaseIdentifier: Hashable, Codable {
    var type: String
    var value: String
    var description: String
}

/// 发行版封面图（一张 release 可有十余张：主图、内页、封套、唱片标签…）
struct CoverImage: Hashable, Codable {
    var uri: String
    var uri150: String
    var type: String
    var width: Int
    var height: Int
}

/// 一张黑胶 = 一个实体副本。discogs_instance_id 为 0 表示纯本地新增（无 Discogs 记录）
struct Record: Identifiable, Hashable {
    var id: Int64                      // SQLite rowid
    var discogsReleaseId: Int          // 0 = 未关联
    var discogsMasterId: Int
    var discogsInstanceId: Int         // 0 = 本地新增
    var discogsFolderId: Int
    var title: String
    var artist: String                 // artists_sort 或拼接
    var artists: [String]
    var year: Int                      // 0 = 未知
    var released: String
    var releasedFormatted: String = ""
    var country: String                // 靠详情补齐
    var genres: [String]
    var styles: [String]
    var labels: [String]
    var catnos: [String]
    var formats: [String]              // 展平后的描述，如 ["Vinyl","LP","Album","Stereo"]
    var formatQuantity: String
    var mainFormat: String             // Vinyl / CD / Box Set ...
    var thumbURL: String
    var coverURL: String
    var trackCount: Int
    var status: String                 // Accepted / Draft
    var dataQuality: String
    var discogsRating: Double          // 社区均分
    var discogsRatingCount: Int
    var haveCount: Int
    var wantCount: Int
    var estimatedWeight: Int?
    var lowestPrice: Double?
    var notes: String
    var discogsURI: String
    var dateAddedToDiscogs: String
    var dateChangedOnDiscogs: String = ""

    // ---- 富详情（拉全量 /releases/{id} 后填充）----
    var tracklist: [Track] = []
    var credits: [Credit] = []
    var companies: [Company] = []
    var identifiers: [ReleaseIdentifier] = []
    var gallery: [CoverImage] = []
    var series: [String] = []
    /// Discogs 原始 JSON 全量留存：任何字段都没丢，将来模型升级可回溯重放
    var rawJSON: String = ""

    // ---- 仅本地字段（不回写 Discogs）----
    var myRating: Int                  // 0-5
    var myNotes: String
    var tags: [String]                 // 自定义标签
    var location: String               // 物理存放位置，如 "A架-2层"
    var condition: String              // M / NM / VG+ ...
    var dateAddedLocal: String
    var detailFetched: Bool            // 是否已拉全详情（决定 country 等字段可信度）
    var statusLocal: String            // owned / wanted / sold

    var displayArtist: String { artist.isEmpty ? "未知艺人" : artist }
    var displayYear: String { year > 0 ? String(year) : "年份未知" }
    var displayCountry: String { country.isEmpty ? "国家未知" : country }
    var decade: Int { year > 0 ? (year / 10) * 10 : 0 }
    var decadeLabel: String { decade > 0 ? "\(decade)s" : "年份未知" }
    var isLocalOnly: Bool { discogsReleaseId == 0 }
    var formatSummary: String {
        var parts: [String] = []
        if !mainFormat.isEmpty { parts.append(mainFormat) }
        let extra = formats.filter { $0 != mainFormat }
        if !extra.isEmpty { parts.append(extra.prefix(3).joined(separator: " · ")) }
        return parts.joined(separator: " ")
    }
    /// 唯一性：同 release 的多副本用此区分
    var duplicateSuffix: String {
        "副本 \(id)"
    }
    /// 制作人员按角色归组
    var creditsByRole: [(role: String, people: [Credit])] {
        var order: [String] = []
        var map: [String: [Credit]] = [:]
        for c in credits {
            let r = c.role.isEmpty ? "其他" : c.role
            if map[r] == nil { order.append(r); map[r] = [] }
            map[r]?.append(c)
        }
        return order.map { ($0, map[$0] ?? []) }
    }
    /// 厂商按类型归组
    var companiesByType: [(type: String, items: [Company])] {
        var order: [String] = []
        var map: [String: [Company]] = [:]
        for c in companies {
            let t = c.entityTypeName.isEmpty ? "其他" : c.entityTypeName
            if map[t] == nil { order.append(t); map[t] = [] }
            map[t]?.append(c)
        }
        return order.map { ($0, map[$0] ?? []) }
    }
    /// 编号按类型归组
    var identifiersByType: [(type: String, items: [ReleaseIdentifier])] {
        var order: [String] = []
        var map: [String: [ReleaseIdentifier]] = [:]
        for x in identifiers {
            let t = x.type.isEmpty ? "其他" : x.type
            if map[t] == nil { order.append(t); map[t] = [] }
            map[t]?.append(x)
        }
        return order.map { ($0, map[$0] ?? []) }
    }
    /// 真实曲数（排除 heading）
    var realTrackCount: Int { tracklist.filter { !$0.isHeading }.count }
}

extension Record {
    /// 由 Discogs 的「列表型」条目（搜索结果 / wantlist 条目）构造占位记录。
    /// 搜索添加与 wantlist 导入共用，避免两处各写一遍字段映射而逐渐跑偏。
    ///
    /// `discogsInstanceId = 0` 表示「本地新增，尚未进入 Discogs 收藏」——
    /// 这是 upsert 去重的锚点，也是「哪些需要推送到 Discogs」的判据。
    static func placeholder(from s: DiscogsSearchResult, statusLocal: String) -> Record {
        let title = s.title ?? ""
        return Record(
            id: 0,
            discogsReleaseId: s.id ?? 0,
            discogsMasterId: s.master_id ?? 0,
            discogsInstanceId: 0,
            discogsFolderId: 0,
            title: title,
            artist: Self.plainArtist(from: title),
            artists: [],
            year: s.year ?? 0,
            released: "", releasedFormatted: "",
            country: s.country ?? "",
            genres: (s.genre ?? []).dedupe(),
            styles: (s.style ?? []).dedupe(),
            labels: (s.label ?? []).filter { !$0.isEmpty }.dedupe(),
            catnos: (s.catno?.trimmed.nilIfEmpty).map { [$0] } ?? [],
            formats: (s.format ?? []).dedupe(),
            formatQuantity: "",
            mainFormat: s.format?.first ?? "",
            thumbURL: s.thumb ?? "",
            coverURL: s.cover_image ?? "",
            trackCount: 0, status: "", dataQuality: "",
            discogsRating: 0, discogsRatingCount: 0, haveCount: 0, wantCount: 0,
            estimatedWeight: nil, lowestPrice: nil, notes: "",
            discogsURI: s.uri ?? "",
            dateAddedToDiscogs: "",
            dateChangedOnDiscogs: "",
            myRating: 0, myNotes: "", tags: [], location: "", condition: "",
            dateAddedLocal: ISO8601DateFormatter().string(from: Date()),
            detailFetched: false,
            statusLocal: statusLocal
        )
    }

    /// Discogs 搜索结果 / wantlist 的 title 是 "艺人 - 专辑"，取艺人部分
    static func plainArtist(from title: String) -> String {
        for sep in [" - ", " – ", " — "] {
            if let r = title.range(of: sep) {
                return String(title[title.startIndex..<r.lowerBound])
            }
        }
        return title
    }

    /// 是否还没进入 Discogs 收藏（instanceId = 0 即本地新增）
    var isPendingPush: Bool { discogsReleaseId > 0 && discogsInstanceId == 0 }
}

/// facet 维度
enum FacetDimension: String, CaseIterable, Identifiable, Codable {
    case genre, style, decade, country, label, format, artist, tag, folder, condition, statusLocal

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .genre: return "流派 Genre"
        case .style: return "风格 Style"
        case .decade: return "年代"
        case .country: return "国家"
        case .label: return "厂牌"
        case .format: return "规格"
        case .artist: return "艺人"
        case .tag: return "自定义标签"
        case .folder: return "Discogs 文件夹"
        case .condition: return "品相"
        case .statusLocal: return "收藏状态"
        }
    }

    var systemImage: String {
        switch self {
        case .genre: return "guitars"
        case .style: return "waveform"
        case .decade: return "calendar"
        case .country: return "globe"
        case .label: return "tag"
        case .format: return "opticaldiscdrive"
        case .artist: return "person"
        case .tag: return "bookmark"
        case .folder: return "folder"
        case .condition: return "sparkles"
        case .statusLocal: return "heart"
        }
    }

    /// 取该维度在某条记录上的所有取值
    func values(of r: Record) -> [String] {
        switch self {
        case .genre: return r.genres
        case .style: return r.styles
        case .decade: return [r.decadeLabel]
        case .country: return [r.country.isEmpty ? "国家未知" : r.country]
        case .label: return r.labels
        case .format: return r.formats.isEmpty ? ["未知"] : r.formats
        case .artist: return r.artists
        case .tag: return r.tags
        case .folder: return ["folder_\(r.discogsFolderId)"]
        case .condition: return [r.condition.isEmpty ? "未标注" : r.condition]
        case .statusLocal: return [r.statusLocal.isEmpty ? "owned" : r.statusLocal]
        }
    }
}

/// 多维筛选条件
struct FacetFilter: Equatable {
    /// dimension.rawValue -> 选中的值集合（空 = 不限）
    var selections: [String: Set<String>] = [:]
    var freeText: String = ""
    /// 同一维度内多选为「或」：选中 1980s + 1990s → 两个年代的全集。
    /// 不同维度之间是「且」：选 国家=US + 年代=1980s → 同时满足两项。
    var yearFrom: Int? = nil
    var yearTo: Int? = nil
    var minRating: Int = 0

    var isEmpty: Bool {
        selections.values.allSatisfy { $0.isEmpty }
            && freeText.trimmed.isEmpty && yearFrom == nil && yearTo == nil && minRating == 0
    }

    var activeDimensionCount: Int {
        selections.values.filter { !$0.isEmpty }.count
    }

    mutating func toggle(dimension: FacetDimension, value: String) {
        var set = selections[dimension.rawValue] ?? []
        if set.contains(value) {
            set.remove(value)
        } else {
            set.insert(value)
        }
        // 空集合就删掉整个 key，避免 isEmpty 判断和计数出现幽灵维度
        selections[dimension.rawValue] = set.isEmpty ? nil : set
    }

    mutating func clearDimension(_ d: FacetDimension) {
        selections[d.rawValue] = nil
    }

    mutating func clearAll() {
        selections.removeAll()
        freeText = ""
        yearFrom = nil
        yearTo = nil
        minRating = 0
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nilIfEmpty: String? { trimmed.isEmpty ? nil : self }
}

extension Array where Element == String {
    /// 保序去重。
    ///
    /// Discogs 的多值字段天然会给出重复项：
    ///   - `formats` 展平后是 `["Vinyl","LP","Vinyl","LP",…]`（同一次发行既有 Vinyl 面又有 LP）
    ///   - `labels` / `artists` 在合作发行里同一名字会出现多次
    /// 不去重的话，详情页会把「Mo Wax」显示两遍，facet 计数也会跟着虚高。
    func dedupe() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}

// MARK: - 同步状态

struct SyncState: Codable {
    var discogsUsername: String = ""
    var lastFullSync: Date?
    var lastPageSynced: Int = 0
    var isSyncing: Bool = false
    var totalItems: Int = 0
    var processedItems: Int = 0
    var detailFetchedCount: Int = 0
    var pendingDetailCount: Int = 0
    var lastError: String?
    var phase: String = ""       // "collection" / "detail" / "idle"
    var rateLimitRemaining: Int = -1
}

enum SyncPhase: String {
    case idle, collection, detail, done
    case failed
}
