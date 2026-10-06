import SwiftUI

/// 从 Discogs 搜索并添加本地新唱片
struct AddRecordView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var added = Set<Int>()
    /// 本次添加是否同时写入 Discogs 收藏
    @State private var alsoToDiscogs = true
    /// 本次添加是否同时写入 Discogs 想读单
    @State private var toWantlist = false

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()

            if !app.isTokenConfigured {
                noToken
            } else if app.searchResults.isEmpty {
                emptyState
            } else {
                resultList
            }

            Divider()
            footer
        }
        .frame(width: 720, height: 660)
        .onAppear {
            if app.searchQuery != query.trimmed && !query.trimmed.isEmpty {
                app.searchQuery = query.trimmed
            }
        }
    }

    // MARK: - 搜索栏

    private var searchBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("艺人 + 专辑名，如 Miles Davis Kind of Blue", text: $query)
                    .textFieldStyle(.plain)
                    .onSubmit { Task { await runSearch() } }
                if app.isSearching { ProgressView().controlSize(.small) }
                Button("搜索") { Task { await runSearch() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(query.trimmed.isEmpty || app.isSearching)
            }

            HStack(spacing: 8) {
                Picker("", selection: $app.searchType) {
                    ForEach(AppState.SearchType.allCases) { t in
                        Text(t.label).tag(t)
                    }
                }
                .labelsHidden()
                .frame(width: 160)
                .onChange(of: app.searchType) { _ in
                    if !app.searchQuery.isEmpty { Task { await runSearch() } }
                }

                Picker("", selection: $app.searchSort) {
                    ForEach(AppState.SearchSort.allCases) { s in
                        Text("按" + s.label).tag(s)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
                .onChange(of: app.searchSort) { _ in
                    if !app.searchQuery.isEmpty { Task { await runSearch() } }
                }

                if app.searchTotal > 0 {
                    Text("共 \(app.searchTotal.formatted()) 条")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .padding(12)
    }

    private func runSearch() async {
        app.searchQuery = query.trimmed
        await app.searchDiscogs(query, page: 1)
        added.removeAll()
    }

    // MARK: - 空态

    private var noToken: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "key.slash")
                .font(.system(size: 30)).foregroundStyle(.orange)
            Text("需要先配置 Discogs Token")
                .font(.headline)
            Text("搜索 Discogs 数据库必须认证。\n请到「设置」粘贴 Personal Access Token。")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer()
            if app.isSearching {
                ProgressView()
                Text("正在搜索 Discogs…").font(.callout).foregroundStyle(.secondary)
            } else {
                Image(systemName: "opticaldisc")
                    .font(.system(size: 30)).foregroundStyle(.secondary.opacity(0.5))
                Text(query.trimmed.isEmpty ? "搜索 Discogs 数据库" : "没有结果")
                    .font(.callout).foregroundStyle(.secondary)
                if !query.trimmed.isEmpty {
                    Text("换个关键词，或把范围切到「专辑 Master」再试")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 结果列表

    private var resultList: some View {
        VStack(spacing: 0) {
            List(app.searchResults, id: \.id) { r in
                SearchResultRow(
                    result: r,
                    inLibrary: app.isInLibrary(r),
                    inCollection: r.user_data?.in_collection ?? false,
                    justAdded: r.id.map { added.contains($0) } ?? false,
                    adding: app.addingReleaseId == r.id,
                    anyAdding: app.addingReleaseId != nil,
                    alsoToDiscogs: alsoToDiscogs
                ) {
                    Task {
                        let ok = await app.addFromDiscogs(r, alsoToDiscogs: alsoToDiscogs,
                                                          toWantlist: toWantlist)
                        if ok, let id = r.id { added.insert(id) }
                    }
                }
            }
            .listStyle(.plain)

            if app.searchPageCount > 1 {
                Divider()
                pager
            }
        }
    }

    private var pager: some View {
        HStack(spacing: 10) {
            Button {
                Task { await app.searchPage(max(1, app.searchPage - 1)) }
            } label: {
                Label("上一页", systemImage: "chevron.left")
            }
            .disabled(app.searchPage <= 1 || app.isSearching)

            Text("第 \(app.searchPage) / \(app.searchPageCount) 页")
                .font(.caption).foregroundStyle(.secondary)
                .monospacedDigit()

            Button {
                Task { await app.searchPage(min(app.searchPageCount, app.searchPage + 1)) }
            } label: {
                Label("下一页", systemImage: "chevron.right")
            }
            .disabled(app.searchPage >= app.searchPageCount || app.isSearching)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - 底栏

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                Toggle("同时加入我的 Discogs 收藏", isOn: $alsoToDiscogs)
                Toggle("加入想读单", isOn: $toWantlist)
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .font(.caption)

            // API 边界如实告知，不做成看起来能删的按钮
            Text("收藏只能新增：Discogs 未开放删除收藏项的 API，本地删掉的唱片无法同步过去。")
                .font(.system(size: 10)).foregroundStyle(.tertiary)

            if !app.statusMessage.isEmpty {
                Text(app.statusMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(app.statusMessage.hasPrefix("搜索失败") || app.statusMessage.hasPrefix("添加失败")
                                     ? Color.red : Color.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
    }
}

// MARK: - 单条搜索结果

private struct SearchResultRow: View {
    let result: DiscogsSearchResult
    let inLibrary: Bool
    let inCollection: Bool
    let justAdded: Bool
    let adding: Bool
    let anyAdding: Bool
    let alsoToDiscogs: Bool
    let onAdd: () -> Void

    private var title: String { result.title ?? "（无标题）" }

    /// 厂牌：搜索结果里 label 数组前几个常是发行商，去重后取前几个更有信息量
    private var labelSummary: String {
        let uniq = (result.label ?? []).dedupe().filter { !$0.isEmpty }
        guard !uniq.isEmpty else { return "" }
        let head = uniq.prefix(3).joined(separator: "、")
        return uniq.count > 3 ? head + " 等 \(uniq.count) 家" : head
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            CachedCover(url: result.thumb ?? "", width: 48, height: 48)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(smartSubtitle)
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .lineLimit(1)
                if !labelSummary.isEmpty {
                    Text(labelSummary)
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    if let g = result.genre, !g.isEmpty {
                        Text(g.joined(separator: " / "))
                            .font(.system(size: 9.5)).foregroundStyle(.tint).lineLimit(1)
                    }
                    if let c = result.community {
                        Text("\(c.have ?? 0) 人持有 · \(c.want ?? 0) 人想要")
                            .font(.system(size: 9.5)).foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 3) {
                if inLibrary {
                    Label(justAdded ? "已加入" : "已在本地",
                          systemImage: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(justAdded ? .green : .secondary)
                } else if adding {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small)
                        Text("添加中").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                } else {
                    Button(action: onAdd) {
                        Text(alsoToDiscogs ? "加入并收藏" : "加入")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(anyAdding)
                }

                if inCollection && !inLibrary {
                    Label("已在 Discogs 收藏", systemImage: "heart.fill")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.orange)
                } else if alsoToDiscogs && !inLibrary && !adding {
                    Text("将写入 Discogs 收藏")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private var smartSubtitle: String {
        var parts: [String] = []
        if let y = result.year, y > 0 { parts.append(String(y)) }
        if let c = result.country, !c.isEmpty { parts.append(c) }
        if let f = result.format?.first, !f.isEmpty { parts.append(f) }
        if let cat = result.catno?.trimmed.nilIfEmpty { parts.append("Cat " + cat) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 统计

struct StatsView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0

    private var o: AppState.Overview { app.overview }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $tab) {
                    Text("概览").tag(0)
                    Text("年代").tag(1)
                    Text("国家").tag(2)
                    Text("流派").tag(3)
                    Text("风格").tag(4)
                    Text("厂牌").tag(5)
                    Text("规格").tag(6)
                }
                .pickerStyle(.segmented)
                .frame(width: 400)
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if tab == 0 { overviewTab }
                    else {
                        let data: [(String, Int)] = switch tab {
                        case 1: o.byDecade
                        case 2: o.byCountry
                        case 3: o.byGenre
                        case 4: o.byStyle
                        case 5: o.byLabel
                        default: o.byFormat
                        }
                        let title = ["", "年代", "国家", "流派", "风格", "厂牌", "规格"][tab]
                        barChart(title: title, data: data)
                    }
                }
                .padding(18)
            }
        }
        .frame(width: 620, height: 560)
    }

    private var overviewTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                statBox("总收藏", "\(o.total)", "opticaldisc")
                statBox("年份跨度", o.yearRange.0 > 0 ? "\(o.yearRange.0)–\(o.yearRange.1)" : "—", "calendar")
                statBox("国家/地区", "\(o.byCountry.count)", "globe")
            }
            HStack(spacing: 14) {
                statBox("厂牌数", "\(o.byLabel.count)", "tag")
                statBox("风格数", "\(o.byStyle.count)", "waveform")
                statBox("缺详情", "\(o.missingDetail)", "exclamationmark.triangle")
            }
            if o.totalLowestPrice > 0 {
                HStack(spacing: 14) {
                    statBox("市场最低价合计", String(format: "$%.2f", o.totalLowestPrice), "dollarsign.circle")
                    statBox("有国家信息", "\(o.withCountry)", "checkmark.seal")
                    statBox("多副本发行", "\(o.duplicateInstances)", "square.on.square")
                }
            }
            Text("说明：统计基于当前本地库。「缺详情」指尚未从 Discogs 拉取完整资料的条目，在设置页执行一次全量重建即可补齐。")
                .font(.caption).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func statBox(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon)
                .font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    private func barChart(title: String, data: [(String, Int)]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title + "分布").font(.headline)
                Spacer()
                Text("\(data.count) 个取值")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if data.isEmpty {
                Text("暂无数据").font(.callout).foregroundStyle(.secondary)
            } else {
                let maxV = data.map(\.1).max() ?? 1
                ForEach(data.prefix(40), id: \.0) { name, count in
                    HStack(spacing: 8) {
                        Text(name)
                            .font(.system(size: 11))
                            .frame(width: 130, alignment: .leading)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.accentColor.opacity(0.75))
                                .frame(width: max(2, geo.size.width * CGFloat(count) / CGFloat(maxV)))
                        }
                        .frame(height: 13)
                        Text("\(count)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .trailing)
                    }
                }
                if data.count > 40 {
                    Text("仅显示前 40 项，共 \(data.count) 项")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }
}
