import Foundation

/// 无头验证程序：真连 Discogs，真写 SQLite，真跑增量同步。
/// 用法：VinylShelfHarness <token> [命令]
///   sync            首次全量导入
///   again           紧接着再跑一次，验证增量（应几乎全为 unchanged）
///   facet <dim>     打印某维度 facet 计数
///   verify          数据一致性校验
@main
struct Harness {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            print("usage: VinylShelfHarness <token> <sync|again|verify|facet|query> [arg]")
            exit(2)
        }
        let token = args[1]
        let cmd = args[2]
        let extra = args.count > 3 ? args[3] : ""

        let dbPath = ProcessInfo.processInfo.environment["VINYLSHELF_TEST_DB"]
            ?? "/tmp/vinylshelf-harness.sqlite"
        // 默认干净起步；VINYLSHELF_KEEP_DB=1 时保留已有库（用于验证增量）
        if ProcessInfo.processInfo.environment["VINYLSHELF_KEEP_DB"] == nil {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: dbPath + suffix)
            }
        }

        do {
            let db = try Database(url: URL(fileURLWithPath: dbPath))
            let client = DiscogsClient()
            client.setToken(token)
            let images = ImageCache(db: db)
            let engine = SyncEngine(client: client, db: db, imageCache: images)

            switch cmd {
            case "sync":
                print("▶ 首次全量同步…")
                let t0 = Date()
                let r = await engine.sync(forceFullDetail: true, downloadImages: false)
                print("▶ 耗时 \(String(format: "%.1f", Date().timeIntervalSince(t0))) 秒")
                print("▶ 报告: \(r.summary)")
                let n = try db.count()
                let st = try db.stats()
                print("▶ 库记录数: \(n)")
                print("▶ 统计: 总\(st.total) 有详情\(st.withDetail) 缺详情\(st.missingDetail) 年\(st.minYear)-\(st.maxYear)")
                try await dumpSamples(db)

            case "again":
                print("▶ 第二次同步（验证增量）…")
                let t0 = Date()
                let r = await engine.sync(forceFullDetail: false, downloadImages: false)
                print("▶ 耗时 \(String(format: "%.1f", Date().timeIntervalSince(t0))) 秒")
                print("▶ 报告: \(r.summary)")
                let n2 = try db.count()
                print("▶ 库记录数: \(n2)")

            case "verify":
                try await verify(db)

            case "facet":
                let dims: [FacetDimension] = extra.isEmpty
                    ? FacetDimension.allCases
                    : [FacetDimension(rawValue: extra)!]
                for d in dims {
                    let counts = try db.facetCounts(dimensions: [d])[d.rawValue] ?? [:]
                    print("── \(d.displayName) (\(counts.count) 个值)")
                    for (v, c) in counts.sorted(by: { $0.value > $1.value }).prefix(20) {
                        print("   \(String(repeating: "  ", count: 0))\(v)  \(c)")
                    }
                }

            case "query":
                let recs = try db.allRecords()
                guard let dim = FacetDimension(rawValue: extra) else {
                    print("维度无效"); exit(2)
                }
                let value = args.count > 4 ? args[4] : ""
                let filt = FacetFilter()
                print("全部 \(recs.count) 条，维度 \(dim.displayName) = \(value)：")
                for r in recs where dim.values(of: r).contains(value) {
                    print("   \(r.artist) — \(r.title) (\(r.displayYear), \(r.displayCountry))")
                }

            case "facetstable":
                try facetStability(db, dimension: extra,
                                   value: args.count > 4 ? args[4] : "")

            case "upserttest":
                try upsertDedupTest(db)

            case "searchtest":
                // 搜索端点字段类型探针：真实调用 + 用 App 的 DTO 解码，
                // 把「网页能搜但 App 报错」这类解码失败全部暴露出来。
                let queries = extra.isEmpty
                    ? ["blue note", "radiohead", " Miles Davis Kind of Blue"]
                    : [extra]
                for q in queries {
                    do {
                        let page = try await client.search(query: q, type: "release", perPage: 50)
                        let rs = page.results ?? []
                        print("✓ 「\(q)」解码成功，\(rs.count) 条 / 共 \(page.pagination?.items ?? 0) 条")
                        var yearTypes = Set<String>()
                        for r in rs {
                            if let y = r.year { yearTypes.insert(y > 0 ? "有年份\(y)" : "year=0") }
                            else { yearTypes.insert("year=nil") }
                        }
                        print("   year 取值形态: \(yearTypes.sorted().joined(separator: ", "))")
                        if let f = rs.first {
                            print("   首条: id=\(f.id ?? -1) 「\(f.title ?? "")」 年=\(f.year ?? -1) 国=\(f.country ?? "nil")")
                            print("   厂牌\(f.label?.count ?? 0) 个(去重后 \(Set(f.label ?? []).count)) / 风格\(f.style?.count ?? 0) / 流派\(f.genre?.count ?? 0) / 格式\(f.format?.count ?? 0)")
                            print("   catno=\(f.catno ?? "nil") master_id=\(f.master_id ?? -1) 在收藏=\(f.user_data?.in_collection.map(String.init) ?? "nil")")
                            print("   封面=\(f.cover_image?.isEmpty == false ? "有" : "空") 缩略图=\(f.thumb?.isEmpty == false ? "有" : "空")")
                        }
                    } catch {
                        print("✗ 「\(q)」失败: \(error.localizedDescription)")
                    }
                }

            case "addtest":
                // 验证「搜索结果 → 本地」的完整链路：占位记录 → 拉全详情 → 下载全部图片。
                // 跑在临时库上，不碰真实收藏。
                guard let rid = Int(extra), rid > 0 else { print("用法：addtest <releaseId>"); exit(2) }
                let sample = DiscogsSearchResult(id: rid, title: "样本 - 链路验证")
                let rowId = try db.upsert(Record.placeholder(from: sample, statusLocal: "owned"))
                print("占位记录已插入 rowid=\(rowId)")
                guard let rec = try db.record(id: rowId) else { print("✗ 读回失败"); exit(1) }
                let ok = await engine.enrich(records: [rec])
                print("enrich: \(ok ? "成功" : "失败")")
                guard let full = try db.record(id: rowId) else { print("✗ 读回失败"); exit(1) }
                print("标题=\(full.title) 艺人=\(full.artist) 年=\(full.year) 国=\(full.country)")
                print("曲目 \(full.tracklist.count) 首 / 人员 \(full.credits.count) / 公司 \(full.companies.count) / 编号 \(full.identifiers.count) / 图集 \(full.gallery.count)")
                print("流派=\(full.genres) 风格数=\(full.styles.count) 厂牌=\(full.labels)")
                var saved = 0
                for img in [full.coverURL] + full.gallery.map(\.uri) where !img.isEmpty {
                    if await images.fetchOne(img, client: client) { saved += 1 }
                }
                print("图片下载 \(saved)/\(1 + full.gallery.count)")
                // 关键回归：enrich 之后不能冒出重复行
                let rows = try db.scalarInt("SELECT COUNT(*) FROM records WHERE discogs_release_id=\(rid)")
                print("该 release 在库行数 = \(rows) \(rows == 1 ? "✓ 无重复" : "✗ 出现重复行")")
                exit(rows == 1 ? 0 : 1)

            case "dedupe":
                let n = try db.dedupeMultiValueFields()
                print("已去重记录数: \(n)")

            default:
                print("未知命令 \(cmd)"); exit(2)
            }

        } catch {
            print("✗ 失败: \(error)")
            exit(1)
        }
    }

    // MARK: - 验证：facet 标签列表不得随筛选塌缩

    /// 守住这个 bug：旧实现 `facetCounts(restrictIds: filteredIds())` 把标签宇宙
    /// 限制在筛选子集内，选中「Electronic」后流派/国家/年代/厂牌的标签集体消失。
    ///
    /// 断言的是 App **实际走的路径**（`restrictIds: nil`）：
    ///   1) 必须与「直接从 records 现算」的真值逐值逐计数相等（且与筛选无关）
    ///   2) 顺带打印旧写法的反例对照，量化这个 bug 当时有多严重
    static func facetStability(_ db: Database, dimension: String, value: String) throws {
        let recs = try db.allRecords()
        guard let dim = FacetDimension(rawValue: dimension) else {
            print("维度无效，合法值：\(FacetDimension.allCases.map(\.rawValue).joined(separator: ", "))")
            exit(2)
        }
        guard !value.isEmpty else { print("用法：facetstable <dim> <value>"); exit(2) }

        // 真值：绕过 facets 索引表，直接从 records 现算
        var truth: [String: [String: Int]] = [:]
        for d in FacetDimension.allCases {
            var t: [String: Int] = [:]
            for r in recs {
                // ⚠️ 必须先对「单条记录内的取值」去重再累加。
                //    Discogs 会给出重复项（formats 展平、合作发行同名字出现多次），
                //    直接累加会高估，与索引表对不上——这是测试算法错，不是索引错。
                for v in d.values(of: r).dedupe() where !v.isEmpty { t[v, default: 0] += 1 }
            }
            truth[d.rawValue] = t
        }

        // App 实际路径：恒为全库口径
        let actual = try db.facetCounts(dimensions: FacetDimension.allCases, restrictIds: nil)

        // 旧写法的反例对照
        let want: Set<String> = [value]
        let subset = recs.filter { !Set(dim.values(of: $0)).isDisjoint(with: want) }
        let ids: Set<Int64> = Set(subset.map { $0.id })
        let old = try db.facetCounts(dimensions: FacetDimension.allCases, restrictIds: ids)

        print("假设用户选中「\(dim.displayName) = \(value)」→ 中间栏 \(subset.count)/\(recs.count) 张\n")
        var regressions = 0
        for d in FacetDimension.allCases {
            let a = actual[d.rawValue] ?? [:]
            let t = truth[d.rawValue] ?? [:]
            let o = old[d.rawValue] ?? [:]
            let ok = a == t
            let lost = Set(t.keys).subtracting(o.keys).count
            if !ok { regressions += 1 }
            print("  \(ok ? "✓" : "✗") \(d.displayName.padding(toLength: 14, withPad: " ", startingAt: 0))"
                  + "\(String(a.count).padding(toLength: 4, withPad: " ", startingAt: 0))个值"
                  + (ok ? "与真值完全一致" : "与真值不符")
                  + "｜旧写法会丢 \(lost) 个标签")
        }
        print(regressions == 0
              ? "\n✓ 全部 \(FacetDimension.allCases.count) 个维度：标签列表恒定，选中任一标签都不会让其他标签消失"
              : "\n✗ \(regressions) 个维度的 facet 计数与真值不符")
        exit(regressions == 0 ? 0 : 1)
    }

    // MARK: - 验证：upsert 不得插出重复行

    /// 两个场景：
    ///  1) 本地新增行（instance_id=0）连续 upsert 两次 —— 唯一索引是部分索引不含 0，
    ///     若走 INSERT+ON CONFLICT 会插出第二行。
    ///  2) 该本地行被「收养」：同一个 release 以 instance_id>0 回来 —— 必须原地更新，不能新增。
    static func upsertDedupTest(_ db: Database) throws {
        let testRelease = 999_000_001
        // 清理：必须走正规删除路径，否则 facets 会留下孤儿行、
        // 让后续所有 facet 计数凭空 +1（曾经真的污染过真实库）
        try purgeTestRecord(db, releaseId: testRelease)

        var r = Record.placeholder(
            from: DiscogsSearchResult(id: testRelease, title: "去重测试 - 本地新增", year: 1999),
            statusLocal: "owned")
        r.myRating = 4          // 本地字段，验证同步时不被覆盖
        r.myNotes = "我的备注"

        let id1 = try db.upsert(r)
        let id2 = try db.upsert(r)
        var rows = try db.scalarInt("SELECT COUNT(*) FROM records WHERE discogs_release_id=\(testRelease)")
        print("场景1 本地行 upsert 两次 → rowid \(id1)/\(id2)，行数 \(rows)")
        let ok1 = rows == 1 && id1 == id2

        // 场景2：Discogs 分配了 instance_id，同一 release 回来
        var adopted = r
        adopted.id = id1
        adopted.discogsInstanceId = 2_222_222_222
        adopted.discogsFolderId = 1
        adopted.year = 2000
        let id3 = try db.upsert(adopted)
        rows = try db.scalarInt("SELECT COUNT(*) FROM records WHERE discogs_release_id=\(testRelease)")
        let rec = try db.record(id: id1)
        print("场景2 收养（instance_id 回来）→ rowid \(id3)，行数 \(rows)，"
              + "年份=\(rec?.year ?? -1) instance=\(rec?.discogsInstanceId ?? -1) "
              + "评分=\(rec?.myRating ?? -1) 备注=\(rec?.myNotes ?? "")")
        let ok2 = rows == 1 && id3 == id1 && rec?.year == 2000
            && rec?.discogsInstanceId == 2_222_222_222
        let ok3 = rec?.myRating == 4 && rec?.myNotes == "我的备注"   // 本地字段未被覆盖

        try purgeTestRecord(db, releaseId: testRelease)
        print(ok1 && ok2 && ok3 ? "\n✓ upsert 去重与本地字段保护均正确" : "\n✗ upsert 存在重复行或字段覆盖问题")
        exit(ok1 && ok2 && ok3 ? 0 : 1)
    }

    /// 按正规路径删掉测试记录：records + facets + 指纹一起清，最后兜底扫孤儿
    static func purgeTestRecord(_ db: Database, releaseId: Int) throws {
        for r in try db.records(releaseId: releaseId) {
            try db.delete(id: r.id)
        }
        try db.exec("DELETE FROM records WHERE discogs_release_id=\(releaseId)")
        _ = try db.deleteOrphanFacets()
    }

    static func dumpSamples(_ db: Database) async throws {
        let recs = try db.allRecords()
        print("\n── 抽样 5 条（验证 country/tracklist 是否补齐）")
        for r in recs.prefix(5) {
            print("   \(r.artist) — \(r.title)")
            print("      id=\(r.discogsReleaseId) inst=\(r.discogsInstanceId) 年=\(r.year) 国=\(r.country) 曲=\(r.trackCount) 详情=\(r.detailFetched)")
            print("      流派=\(r.genres) 风格=\(r.styles.prefix(3).joined(separator: ", ")) 规格=\(r.formatSummary)")
        }
        let withCountry = recs.filter { !$0.country.isEmpty }.count
        let withDetail = recs.filter(\.detailFetched).count
        print("\n── 覆盖: country \(withCountry)/\(recs.count)，detailFetched \(withDetail)/\(recs.count)")
        let dupRelease = Dictionary(grouping: recs, by: \.discogsReleaseId)
            .filter { $0.value.count > 1 }
        print("── 同 release 多副本: \(dupRelease.count) 组")
        for (k, v) in dupRelease { print("   release \(k): \(v.count) 副本") }
    }

    static func verify(_ db: Database) async throws {
        let recs = try db.allRecords()
        let s = try db.stats()
        print("── 总数 \(s.total)")
        print("── 详情已拉 \(s.withDetail)，缺详情 \(s.missingDetail)")
        print("── 年份 \(s.minYear)…\(s.maxYear)，累计最低价 \(String(format: "%.2f", s.totalValue))")
        print("── country 覆盖 \(recs.filter { !$0.country.isEmpty }.count)/\(recs.count)")
        print("── year 覆盖 \(recs.filter { $0.year > 0 }.count)/\(recs.count)")
        print("── trackCount>0: \(recs.filter { $0.trackCount > 0 }.count)")
        // facet 索引一致性
        var mismatch = 0
        for d in FacetDimension.allCases {
            let counts = try db.facetCounts(dimensions: [d])[d.rawValue] ?? [:]
            let total = counts.values.reduce(0, +)
            let expected = recs.filter { !d.values(of: $0).filter({ !$0.isEmpty }).isEmpty }.count
            if total < expected { mismatch += 1 }
            print("── \(d.rawValue): 索引条目 \(total) / 应覆盖记录 \(expected)")
        }
        print(mismatch == 0 ? "\n✓ facet 索引一致" : "\n✗ \(mismatch) 个维度索引不足")
    }
}
