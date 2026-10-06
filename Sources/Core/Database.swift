import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum DBError: LocalizedError {
    case open(String)
    case exec(String)
    case prepare(String)

    var errorDescription: String? {
        switch self {
        case .open(let m): return "数据库打开失败: \(m)"
        case .exec(let m): return "SQL 执行失败: \(m)"
        case .prepare(let m): return "SQL 预处理失败: \(m)"
        }
    }
}

/// SQLite 封装：记录存储 + facet 索引 + 检索
final class Database {
    private var db: OpaquePointer?
    let url: URL

    init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let h = handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let h = handle { sqlite3_close_v2(h) }
            throw DBError.open(msg)
        }
        db = h
        // WAL + 忙等待，导入时并发读写不炸
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA synchronous=NORMAL;")
        try exec("PRAGMA foreign_keys=ON;")
        try exec("PRAGMA busy_timeout=5000;")
        try migrate()
    }

    deinit { if let d = db { sqlite3_close_v2(d) } }

    // MARK: - 基础执行

    @discardableResult
    func exec(_ sql: String) throws -> Int {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw DBError.exec(msg)
        }
        return Int(sqlite3_changes(db))
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw DBError.prepare(String(cString: sqlite3_errmsg(db)))
        }
        return s
    }

    /// 绑定参数：支持 String / Int / Int64 / Double / nil
    private func bind(_ values: [Any?], to stmt: OpaquePointer, from index: Int32 = 1) {
        for (i, v) in values.enumerated() {
            let idx = index + Int32(i)
            if v == nil || v is NSNull {
                sqlite3_bind_null(stmt, idx)
            } else if let s = v as? String {
                sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
            } else if let b = v as? Bool {
                sqlite3_bind_int(stmt, idx, b ? 1 : 0)
            } else if let i = v as? Int64 {
                sqlite3_bind_int64(stmt, idx, i)
            } else if let i = v as? Int {
                sqlite3_bind_int64(stmt, idx, Int64(i))
            } else if let d = v as? Double {
                sqlite3_bind_double(stmt, idx, d)
            } else {
                sqlite3_bind_text(stmt, idx, String(describing: v!), -1, SQLITE_TRANSIENT)
            }
        }
    }

    // MARK: - Schema

    private func migrate() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS records (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            discogs_release_id INTEGER NOT NULL DEFAULT 0,
            discogs_master_id INTEGER NOT NULL DEFAULT 0,
            discogs_instance_id INTEGER NOT NULL DEFAULT 0,
            discogs_folder_id INTEGER NOT NULL DEFAULT 0,
            title TEXT NOT NULL DEFAULT '',
            artist TEXT NOT NULL DEFAULT '',
            artists_json TEXT NOT NULL DEFAULT '[]',
            year INTEGER NOT NULL DEFAULT 0,
            released TEXT NOT NULL DEFAULT '',
            country TEXT NOT NULL DEFAULT '',
            genres_json TEXT NOT NULL DEFAULT '[]',
            styles_json TEXT NOT NULL DEFAULT '[]',
            labels_json TEXT NOT NULL DEFAULT '[]',
            catnos_json TEXT NOT NULL DEFAULT '[]',
            formats_json TEXT NOT NULL DEFAULT '[]',
            main_format TEXT NOT NULL DEFAULT '',
            format_quantity TEXT NOT NULL DEFAULT '',
            thumb_url TEXT NOT NULL DEFAULT '',
            cover_url TEXT NOT NULL DEFAULT '',
            track_count INTEGER NOT NULL DEFAULT 0,
            status TEXT NOT NULL DEFAULT '',
            data_quality TEXT NOT NULL DEFAULT '',
            discogs_rating REAL NOT NULL DEFAULT 0,
            discogs_rating_count INTEGER NOT NULL DEFAULT 0,
            have_count INTEGER NOT NULL DEFAULT 0,
            want_count INTEGER NOT NULL DEFAULT 0,
            estimated_weight INTEGER,
            lowest_price REAL,
            notes TEXT NOT NULL DEFAULT '',
            discogs_uri TEXT NOT NULL DEFAULT '',
            date_added_discogs TEXT NOT NULL DEFAULT '',
            my_rating INTEGER NOT NULL DEFAULT 0,
            my_notes TEXT NOT NULL DEFAULT '',
            tags_json TEXT NOT NULL DEFAULT '[]',
            location TEXT NOT NULL DEFAULT '',
            condition TEXT NOT NULL DEFAULT '',
            date_added_local TEXT NOT NULL DEFAULT '',
            detail_fetched INTEGER NOT NULL DEFAULT 0,
            status_local TEXT NOT NULL DEFAULT 'owned',
            released_formatted TEXT NOT NULL DEFAULT '',
            date_changed_discogs TEXT NOT NULL DEFAULT '',
            tracklist_json TEXT NOT NULL DEFAULT '[]',
            credits_json TEXT NOT NULL DEFAULT '[]',
            companies_json TEXT NOT NULL DEFAULT '[]',
            identifiers_json TEXT NOT NULL DEFAULT '[]',
            gallery_json TEXT NOT NULL DEFAULT '[]',
            series_json TEXT NOT NULL DEFAULT '[]',
            raw_json TEXT NOT NULL DEFAULT ''
        );
        """)

        // instance_id 唯一：同一 Discogs 实体副本不重复导入
        try exec("""
        CREATE UNIQUE INDEX IF NOT EXISTS idx_records_instance
            ON records(discogs_instance_id) WHERE discogs_instance_id > 0;
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_records_release ON records(discogs_release_id);")
        try exec("CREATE INDEX IF NOT EXISTS idx_records_year ON records(year);")
        try exec("CREATE INDEX IF NOT EXISTS idx_records_country ON records(country);")
        try exec("CREATE INDEX IF NOT EXISTS idx_records_artist ON records(artist);")
        try exec("CREATE INDEX IF NOT EXISTS idx_records_detail ON records(detail_fetched);")

        // facet 反范式表：一个 (record, dimension, value) 一行，检索时走索引
        try exec("""
        CREATE TABLE IF NOT EXISTS facets (
            record_id INTEGER NOT NULL,
            dimension TEXT NOT NULL,
            value TEXT NOT NULL,
            PRIMARY KEY (record_id, dimension, value)
        ) WITHOUT ROWID;
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_facets_dim_val ON facets(dimension, value);")
        try exec("CREATE INDEX IF NOT EXISTS idx_facets_rec ON facets(record_id);")

        // 封面图本地缓存路径
        try exec("""
        CREATE TABLE IF NOT EXISTS images (
            url TEXT PRIMARY KEY,
            local_path TEXT NOT NULL DEFAULT '',
            fetched_at REAL NOT NULL DEFAULT 0,
            bytes INTEGER NOT NULL DEFAULT 0
        ) WITHOUT ROWID;
        """)

        try exec("""
        CREATE TABLE IF NOT EXISTS meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        ) WITHOUT ROWID;
        """)

        // 列表层指纹：instance_id -> collection 端点字段指纹。
        // Discogs 的 collection 端点不返回 date_changed（实测 0/299），
        // 所以增量同步只能靠这个指纹判断「线上这条是否被改过」。
        try exec("""
        CREATE TABLE IF NOT EXISTS collection_fingerprints (
            instance_id INTEGER PRIMARY KEY,
            fingerprint TEXT NOT NULL,
            last_seen REAL NOT NULL
        ) WITHOUT ROWID;
        """)
    }

    // MARK: - Meta

    func setMeta(_ key: String, _ value: String) throws {
        let sql = "INSERT INTO meta(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value;"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        bind([key, value], to: stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw DBError.exec(errMsg) }
    }

    func getMeta(_ key: String) -> String? {
        guard let stmt = try? prepare("SELECT value FROM meta WHERE key=?") else { return nil }
        defer { sqlite3_finalize(stmt) }
        bind([key], to: stmt)
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let c = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: c)
    }

    private var errMsg: String { String(cString: sqlite3_errmsg(db)) }

    // MARK: - 写入

    /// 仅本地字段：Discogs 同步回来时**不得**覆盖，否则用户的评分/备注/品相会被冲掉
    private static let localOnlyColumns: Set<String> = [
        "my_rating", "my_notes", "tags_json", "location", "condition",
        "date_added_local", "status_local"
    ]

    /// upsert 可写列：(列名, 取值)。INSERT 与 UPDATE 共用同一份清单，
    /// 避免两处列名各写一遍、日久漂移成「少更新一列」这种静默数据错误。
    private static let upsertFields: [(String, (Record) -> Any?)] = [
        ("discogs_release_id",  { $0.discogsReleaseId }),
        ("discogs_master_id",   { $0.discogsMasterId }),
        ("discogs_instance_id", { $0.discogsInstanceId }),
        ("discogs_folder_id",   { $0.discogsFolderId }),
        ("title",               { $0.title }),
        ("artist",              { $0.artist }),
        ("artists_json",        { Database.enc($0.artists) }),
        ("year",                { $0.year }),
        ("released",            { $0.released }),
        ("country",             { $0.country }),
        ("genres_json",         { Database.enc($0.genres) }),
        ("styles_json",         { Database.enc($0.styles) }),
        ("labels_json",         { Database.enc($0.labels) }),
        ("catnos_json",         { Database.enc($0.catnos) }),
        ("formats_json",        { Database.enc($0.formats) }),
        ("main_format",         { $0.mainFormat }),
        ("format_quantity",     { $0.formatQuantity }),
        ("thumb_url",           { $0.thumbURL }),
        ("cover_url",           { $0.coverURL }),
        ("track_count",         { $0.trackCount }),
        ("status",              { $0.status }),
        ("data_quality",        { $0.dataQuality }),
        ("discogs_rating",      { $0.discogsRating }),
        ("discogs_rating_count",{ $0.discogsRatingCount }),
        ("have_count",          { $0.haveCount }),
        ("want_count",          { $0.wantCount }),
        ("estimated_weight",    { $0.estimatedWeight }),
        ("lowest_price",        { $0.lowestPrice }),
        ("notes",               { $0.notes }),
        ("discogs_uri",         { $0.discogsURI }),
        ("date_added_discogs",  { $0.dateAddedToDiscogs }),
        ("my_rating",           { $0.myRating }),
        ("my_notes",            { $0.myNotes }),
        ("tags_json",           { Database.enc($0.tags) }),
        ("location",            { $0.location }),
        ("condition",           { $0.condition }),
        ("date_added_local",    { $0.dateAddedLocal }),
        ("detail_fetched",      { $0.detailFetched ? 1 : 0 }),
        ("status_local",        { $0.statusLocal }),
        ("released_formatted",  { $0.releasedFormatted }),
        ("date_changed_discogs",{ $0.dateChangedOnDiscogs }),
        ("tracklist_json",      { Database.encTracklist($0.tracklist) }),
        ("credits_json",        { Database.encCredits($0.credits) }),
        ("companies_json",      { Database.encCompanies($0.companies) }),
        ("identifiers_json",    { Database.encIdentifiers($0.identifiers) }),
        ("gallery_json",        { Database.encGallery($0.gallery) }),
        ("series_json",         { Database.enc($0.series) }),
        ("raw_json",            { $0.rawJSON })
    ]

    /// 插入或更新一条记录。返回 rowid。
    ///
    /// 命中已有行时走 **UPDATE 而非 INSERT**：唯一索引是部分索引
    /// `WHERE discogs_instance_id > 0`，`instance_id = 0` 的本地新增行不受约束，
    /// 若仍走 INSERT+ON CONFLICT，同一条本地记录第二次 upsert 会插出重复行。
    @discardableResult
    func upsert(_ r: Record, collectionFingerprint: String? = nil) throws -> Int64 {
        let existing = try findIdByInstance(r.discogsInstanceId, releaseId: r.discogsReleaseId)
        let rowId: Int64

        if let existing {
            let fields = Self.upsertFields.filter { !Self.localOnlyColumns.contains($0.0) }
            let sql = "UPDATE records SET \(fields.map { "\($0.0)=?" }.joined(separator: ",")) WHERE id=?"
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            bind(fields.map { $0.1(r) } + [existing], to: stmt)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw DBError.exec(errMsg) }
            rowId = existing
        } else {
            let cols = Self.upsertFields.map(\.0).joined(separator: ",")
            let holes = Array(repeating: "?", count: Self.upsertFields.count).joined(separator: ",")
            let stmt = try prepare("INSERT INTO records (\(cols)) VALUES (\(holes))")
            defer { sqlite3_finalize(stmt) }
            bind(Self.upsertFields.map { $0.1(r) }, to: stmt)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw DBError.exec(errMsg) }
            rowId = Int64(sqlite3_last_insert_rowid(db))
        }

        try rebuildFacets(recordId: rowId, record: r)
        if let fp = collectionFingerprint, r.discogsInstanceId > 0 {
            try saveFingerprint(instanceId: r.discogsInstanceId, fingerprint: fp)
        }
        return rowId
    }

    // MARK: - 列表层指纹（增量同步用）

    private func saveFingerprint(instanceId: Int, fingerprint: String) throws {
        let stmt = try prepare(
            "INSERT INTO collection_fingerprints(instance_id,fingerprint,last_seen) VALUES(?,?,?) ON CONFLICT(instance_id) DO UPDATE SET fingerprint=excluded.fingerprint, last_seen=excluded.last_seen")
        defer { sqlite3_finalize(stmt) }
        bind([instanceId, fingerprint, Date().timeIntervalSince1970], to: stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw DBError.exec(errMsg) }
    }

    func allCollectionFingerprints() throws -> [String: String] {
        let stmt = try prepare("SELECT instance_id, fingerprint FROM collection_fingerprints")
        defer { sqlite3_finalize(stmt) }
        var out: [String: String] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let key = String(sqlite3_column_int64(stmt, 0))
            if let c = sqlite3_column_text(stmt, 1) {
                out[key] = String(cString: c)
            }
        }
        return out
    }

    /// 同步后清理已不存在的指纹
    func pruneFingerprints(keeping keys: Set<String>) throws {
        let all = try allCollectionFingerprints()
        let stale = all.keys.filter { !keys.contains($0) }
        guard !stale.isEmpty else { return }
        try exec("BEGIN")
        for k in stale { try exec("DELETE FROM collection_fingerprints WHERE instance_id=\(k)") }
        try exec("COMMIT")
    }

    private func findIdByInstance(_ instanceId: Int, releaseId: Int) throws -> Int64? {
        // 1) 按 instance 精确命中（同一副本重复同步走这里）
        if instanceId > 0, let hit = try firstId("SELECT id FROM records WHERE discogs_instance_id=?", [instanceId]) {
            return hit
        }
        // 2) 收养本地新增行（instance_id = 0）
        //
        // 场景：搜索添加进本地的记录 instance_id=0，推送到 Discogs 收藏后，
        // 下次同步会带着 Discogs 分配的 instance_id 回来。若只按 instance 匹配，
        // 这条本地记录就会被判为「不存在」→ INSERT 出第二行同一 release 的重复记录。
        // 这里让它被原地收养，顺带把 instance_id / folder_id 补上。
        //
        // 安全前提：只有 instance_id=0 的行会被收养，而同一 release 的多个副本
        // 在 Discogs 侧各有独立 instance_id 且都 >0，不会互相抢占。
        guard releaseId > 0 else { return nil }
        return try firstId("SELECT id FROM records WHERE discogs_release_id=? AND discogs_instance_id=0", [releaseId])
    }

    private func firstId(_ sql: String, _ params: [Any?]) throws -> Int64? {
        guard let stmt = try? prepare(sql) else { return nil }
        defer { sqlite3_finalize(stmt) }
        bind(params, to: stmt)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(stmt, 0)
    }

    private static func encodeJSON<T: Encodable>(_ v: T) -> String {
        guard let d = try? JSONEncoder().encode(v), let s = String(data: d, encoding: .utf8) else {
            return "[]"
        }
        return s
    }

    private func decodeJSONArray(_ s: String) -> [String] {
        guard let d = s.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: d) else { return [] }
        return arr
    }

    // MARK: 富详情编解码

    // Track / Credit / Company / ReleaseIdentifier / CoverImage 均已 Codable，直接编解码
    private static func enc<T: Encodable>(_ v: T) -> String {
        guard let d = try? JSONEncoder().encode(v), let s = String(data: d, encoding: .utf8) else {
            return "[]"
        }
        return s
    }

    private static func dec<T: Decodable>(_ s: String, _ fallback: T) -> T {
        guard let d = s.data(using: .utf8),
              let v = try? JSONDecoder().decode(T.self, from: d) else { return fallback }
        return v
    }

    private static func encTracklist(_ v: [Track]) -> String { enc(v) }
    private static func decTracklist(_ s: String) -> [Track] { dec(s, []) }
    private static func encCredits(_ v: [Credit]) -> String { enc(v) }
    private static func decCredits(_ s: String) -> [Credit] { dec(s, []) }
    private static func encCompanies(_ v: [Company]) -> String { enc(v) }
    private static func decCompanies(_ s: String) -> [Company] { dec(s, []) }
    private static func encIdentifiers(_ v: [ReleaseIdentifier]) -> String { enc(v) }
    private static func decIdentifiers(_ s: String) -> [ReleaseIdentifier] { dec(s, []) }
    private static func encGallery(_ v: [CoverImage]) -> String { enc(v) }
    private static func decGallery(_ s: String) -> [CoverImage] { dec(s, []) }


    /// 重建某条记录的全部 facet 索引
    private func rebuildFacets(recordId: Int64, record r: Record) throws {
        try exec("DELETE FROM facets WHERE record_id=\(recordId)")
        let stmt = try prepare("INSERT OR IGNORE INTO facets(record_id,dimension,value) VALUES(?,?,?)")
        defer { sqlite3_finalize(stmt) }
        try exec("BEGIN")
        for dim in FacetDimension.allCases {
            for value in dim.values(of: r) where !value.isEmpty {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                bind([Int64(recordId), dim.rawValue, value], to: stmt)
                _ = sqlite3_step(stmt)
            }
        }
        try exec("COMMIT")
    }

    // MARK: - 本地字段更新（不覆盖 Discogs 字段）

    func updateLocalFields(id: Int64,
                           myRating: Int? = nil, myNotes: String? = nil,
                           tags: [String]? = nil, location: String? = nil,
                           condition: String? = nil, statusLocal: String? = nil) throws {
        var sets: [String] = []
        var params: [Any?] = []
        if let v = myRating { sets.append("my_rating=?"); params.append(v) }
        if let v = myNotes { sets.append("my_notes=?"); params.append(v) }
        if let v = tags { sets.append("tags_json=?"); params.append(Self.enc(v)) }
        if let v = location { sets.append("location=?"); params.append(v) }
        if let v = condition { sets.append("condition=?"); params.append(v) }
        if let v = statusLocal { sets.append("status_local=?"); params.append(v) }
        guard !sets.isEmpty else { return }
        params.append(id)
        let sql = "UPDATE records SET \(sets.joined(separator: ",")) WHERE id=?"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        bind(params, to: stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw DBError.exec(errMsg) }

        // 标签/品相/状态参与 facet，需重建
        if tags != nil || condition != nil || statusLocal != nil,
           let rec = try record(id: id) {
            try rebuildFacets(recordId: id, record: rec)
        }
    }

    func delete(id: Int64) throws {
        try exec("DELETE FROM facets WHERE record_id=\(id)")
        if let r = try record(id: id), r.discogsInstanceId > 0 {
            try exec("DELETE FROM collection_fingerprints WHERE instance_id=\(r.discogsInstanceId)")
        }
        try exec("DELETE FROM records WHERE id=\(id)")
    }

    // MARK: - 读取

    private static let selectColumns = """
    id, discogs_release_id, discogs_master_id, discogs_instance_id, discogs_folder_id,
    title, artist, artists_json, year, released, country,
    genres_json, styles_json, labels_json, catnos_json, formats_json,
    main_format, format_quantity, thumb_url, cover_url, track_count,
    status, data_quality, discogs_rating, discogs_rating_count, have_count, want_count,
    estimated_weight, lowest_price, notes, discogs_uri, date_added_discogs,
    my_rating, my_notes, tags_json, location, condition, date_added_local,
    detail_fetched, status_local,
    released_formatted, date_changed_discogs,
    tracklist_json, credits_json, companies_json, identifiers_json, gallery_json,
    series_json, raw_json
    """

    private func record(from stmt: OpaquePointer) -> Record {
        func s(_ i: Int32) -> String {
            guard let c = sqlite3_column_text(stmt, i) else { return "" }
            return String(cString: c)
        }
        func i(_ i: Int32) -> Int { Int(sqlite3_column_int64(stmt, i)) }
        func d(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }

        return Record(
            id: sqlite3_column_int64(stmt, 0),
            discogsReleaseId: i(1), discogsMasterId: i(2),
            discogsInstanceId: i(3), discogsFolderId: i(4),
            title: s(5), artist: s(6),
            artists: decodeJSONArray(s(7)),
            year: i(8), released: s(9),
            releasedFormatted: s(40),
            country: s(10),
            genres: decodeJSONArray(s(11)), styles: decodeJSONArray(s(12)),
            labels: decodeJSONArray(s(13)), catnos: decodeJSONArray(s(14)),
            formats: decodeJSONArray(s(15)),
            formatQuantity: s(17), mainFormat: s(16),
            thumbURL: s(18), coverURL: s(19), trackCount: i(20),
            status: s(21), dataQuality: s(22),
            discogsRating: d(23), discogsRatingCount: i(24),
            haveCount: i(25), wantCount: i(26),
            estimatedWeight: sqlite3_column_type(stmt, 27) == SQLITE_NULL ? nil : i(27),
            lowestPrice: sqlite3_column_type(stmt, 28) == SQLITE_NULL ? nil : d(28),
            notes: s(29), discogsURI: s(30), dateAddedToDiscogs: s(31),
            dateChangedOnDiscogs: s(41),
            tracklist: Self.decTracklist(s(42)),
            credits: Self.decCredits(s(43)),
            companies: Self.decCompanies(s(44)),
            identifiers: Self.decIdentifiers(s(45)),
            gallery: Self.decGallery(s(46)),
            series: decodeJSONArray(s(47)),
            rawJSON: s(48),
            myRating: i(32), myNotes: s(33),
            tags: decodeJSONArray(s(34)),
            location: s(35), condition: s(36), dateAddedLocal: s(37),
            detailFetched: i(38) == 1, statusLocal: s(39)
        )
    }

    func allRecords() throws -> [Record] {
        let sql = "SELECT \(Self.selectColumns) FROM records ORDER BY artist COLLATE NOCASE, year, title"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        var out: [Record] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(record(from: stmt)) }
        return out
    }

    func record(id: Int64) throws -> Record? {
        let sql = "SELECT \(Self.selectColumns) FROM records WHERE id=?"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        bind([id], to: stmt)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return record(from: stmt)
    }

    /// 同一 release 的所有实体副本
    func records(releaseId: Int) throws -> [Record] {
        let sql = "SELECT \(Self.selectColumns) FROM records WHERE discogs_release_id=?"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        bind([releaseId], to: stmt)
        var out: [Record] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(record(from: stmt)) }
        return out
    }

    func count() throws -> Int {
        let stmt = try prepare("SELECT COUNT(*) FROM records")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    func releaseIdsMissingDetail(limit: Int) throws -> [Int] {
        let sql = """
        SELECT DISTINCT discogs_release_id FROM records
        WHERE detail_fetched=0 AND discogs_release_id>0
        ORDER BY discogs_release_id LIMIT ?
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        bind([limit], to: stmt)
        var out: [Int] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(Int(sqlite3_column_int64(stmt, 0)))
        }
        return out
    }

    func countMissingDetail() throws -> Int {
        let stmt = try prepare(
            "SELECT COUNT(DISTINCT discogs_release_id) FROM records WHERE detail_fetched=0 AND discogs_release_id>0")
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// 单值查询（返回第一行第一列的整数）。
    /// ⚠️ 不要用 `exec` 跑 SELECT：它返回的是 sqlite3_changes()，
    ///    对 SELECT 而言是「上一条语句改了几行」，不是结果集行数。
    func scalarInt(_ sql: String) throws -> Int {
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// 一次性数据修复：把多值字段里的重复项去掉。
    ///
    /// 背景：早期版本构造 Record 时没有对 `labels` / `formats` / `artists` 去重，
    /// 而 Discogs 天然会给出重复项（formats 展平成 `Vinyl,LP,Vinyl,LP`；
    /// 合作发行里同一厂牌/艺人出现多次）。表现为详情页把「Mo Wax」显示两遍。
    /// 新写入路径已统一 `dedupe()`，这里用于清理**已落库**的历史数据。
    ///
    /// 只改这 6 个 JSON 列并重建对应记录的 facets，不碰任何 Discogs 字段。
    @discardableResult
    func dedupeMultiValueFields() throws -> Int {
        var fixed = 0
        for r in try allRecords() {
            var next = r
            var changed = false
            func apply(_ kp: WritableKeyPath<Record, [String]>) {
                let before = r[keyPath: kp]
                let after = before.dedupe()
                if before != after { next[keyPath: kp] = after; changed = true }
            }
            apply(\.artists); apply(\.genres); apply(\.styles)
            apply(\.labels); apply(\.catnos); apply(\.formats)
            guard changed else { continue }
            let sql = """
            UPDATE records SET artists_json=?, genres_json=?, styles_json=?,
                   labels_json=?, catnos_json=?, formats_json=? WHERE id=?
            """
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            bind([Self.enc(next.artists), Self.enc(next.genres), Self.enc(next.styles),
                  Self.enc(next.labels), Self.enc(next.catnos), Self.enc(next.formats),
                  r.id], to: stmt)
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw DBError.exec(errMsg) }
            try rebuildFacets(recordId: r.id, record: next)
            fixed += 1
        }
        return fixed
    }

    /// 清理孤儿 facet 行（record_id 已不在 records 中）。
    /// ⚠️ 任何**绕过 `delete(id:)`** 的直接 `DELETE FROM records` 都会留下孤儿行，
    ///    而 facet 计数是 `SELECT value, COUNT(*) FROM facets GROUP BY value`——
    ///    孤儿行会让每个标签的计数凭空 +1，侧栏数字与真实记录数对不上。
    ///    正常路径由 `delete(id:)` 一并清理，这里作为兜底。
    @discardableResult
    func deleteOrphanFacets() throws -> Int {
        try exec("DELETE FROM facets WHERE record_id NOT IN (SELECT id FROM records)")
        return try scalarInt("SELECT COUNT(*) FROM facets WHERE record_id NOT IN (SELECT id FROM records)")
    }

    // MARK: - Facet 计数

    /// 每个维度每个值的命中数（可选：限定在已选中的子集内，用于 drill-down 计数）
    func facetCounts(dimensions: [FacetDimension],
                     restrictIds: Set<Int64>? = nil) throws -> [String: [String: Int]] {
        var result: [String: [String: Int]] = [:]
        for dim in dimensions {
            var sql = """
            SELECT f.value, COUNT(*) FROM facets f
            WHERE f.dimension=?
            """
            var params: [Any?] = [dim.rawValue]
            if let ids = restrictIds, !ids.isEmpty {
                let list = ids.map(String.init).joined(separator: ",")
                sql += " AND f.record_id IN (\(list))"
            } else if let ids = restrictIds, ids.isEmpty {
                result[dim.rawValue] = [:]
                continue
            }
            sql += " GROUP BY f.value ORDER BY COUNT(*) DESC, f.value ASC"
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            bind(params, to: stmt)
            var counts: [String: Int] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let c = sqlite3_column_text(stmt, 0) else { continue }
                counts[String(cString: c)] = Int(sqlite3_column_int64(stmt, 1))
            }
            result[dim.rawValue] = counts
        }
        return result
    }

    /// 全局统计
    struct Stats {
        var total: Int = 0
        var withDetail: Int = 0
        var missingDetail: Int = 0
        var minYear: Int = 0
        var maxYear: Int = 0
        var totalValue: Double = 0
    }

    func stats() throws -> Stats {
        var s = Stats()
        let sql = """
        SELECT COUNT(*),
               SUM(CASE WHEN detail_fetched=1 THEN 1 ELSE 0 END),
               SUM(CASE WHEN detail_fetched=0 AND discogs_release_id>0 THEN 1 ELSE 0 END),
               MIN(CASE WHEN year>0 THEN year END),
               MAX(CASE WHEN year>0 THEN year END),
               SUM(CASE WHEN lowest_price IS NOT NULL THEN lowest_price ELSE 0 END)
        FROM records
        """
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return s }
        s.total = Int(sqlite3_column_int64(stmt, 0))
        s.withDetail = Int(sqlite3_column_int64(stmt, 1))
        s.missingDetail = Int(sqlite3_column_int64(stmt, 2))
        s.minYear = Int(sqlite3_column_int64(stmt, 3))
        s.maxYear = Int(sqlite3_column_int64(stmt, 4))
        s.totalValue = sqlite3_column_double(stmt, 5)
        return s
    }

    // MARK: - 图片缓存索引

    func cachedImagePath(for url: String) -> String? {
        guard let stmt = try? prepare("SELECT local_path FROM images WHERE url=? AND bytes>0") else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        bind([url], to: stmt)
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let c = sqlite3_column_text(stmt, 0) else { return nil }
        let p = String(cString: c)
        return p.isEmpty ? nil : p
    }

    func recordImage(url: String, localPath: String, bytes: Int) {
        guard let stmt = try? prepare(
            "INSERT INTO images(url,local_path,fetched_at,bytes) VALUES(?,?,?,?) ON CONFLICT(url) DO UPDATE SET local_path=excluded.local_path, fetched_at=excluded.fetched_at, bytes=excluded.bytes")
        else { return }
        defer { sqlite3_finalize(stmt) }
        bind([url, localPath, Date().timeIntervalSince1970, bytes], to: stmt)
        _ = sqlite3_step(stmt)
    }
}
