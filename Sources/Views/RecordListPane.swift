import SwiftUI

/// 中栏：网格 / 列表两种视图 + 搜索框
struct RecordListPane: View {
    @EnvironmentObject var app: AppState
    @State private var searchField = ""

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            if app.filteredRecords().isEmpty {
                emptyState
            } else if app.viewMode == .grid {
                grid
                countBar
            } else {
                list
                countBar
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .facetFilterChanged)) { _ in
            // facet 变化后重算 drill-down 计数
            app.recomputeFacets()
        }
    }

    /// 底部数量条
    private var countBar: some View {
        HStack(spacing: 10) {
            Text("显示 \(app.filteredCount) / \(app.totalCount) 张")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if !app.filter.isEmpty {
                Text("· 已启用 \(app.filter.activeDimensionCount) 个维度筛选")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if app.filteredCount < app.totalCount && app.totalCount > 0 {
                Button("清除筛选") {
                    withAnimation { app.filter.clearAll() }
                    app.recomputeFacets()
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索艺人、标题、厂牌、风格…", text: $searchField)
                .textFieldStyle(.plain)
                .onSubmit { app.searchText = searchField }
            if !searchField.isEmpty {
                Button {
                    searchField = ""
                    app.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            VinylGlyph().frame(width: 64, height: 64)
            if app.totalCount == 0 {
                Text(app.isTokenConfigured ? "还没有数据" : "请先配置 Discogs Token")
                    .font(.headline)
                Text(app.isTokenConfigured
                     ? "点工具栏「设置」执行首次同步"
                     : "设置页粘贴 Personal Access Token 后即可导入收藏")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("没有符合条件的唱片")
                    .font(.headline)
                Text("试试清除部分筛选条件")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 138, maximum: 190), spacing: 14)],
                      spacing: 14) {
                ForEach(app.filteredRecords()) { r in
                    RecordGridCard(record: r)
                }
            }
            .padding(12)
        }
    }

    private var list: some View {
        List {
            ForEach(app.filteredRecords()) { r in
                RecordListRow(record: r)
                    .contentShape(Rectangle())
                    .onTapGesture { app.selectedId = r.id }
                    .contextMenu { contextMenu(for: r) }
            }
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private func contextMenu(for r: Record) -> some View {
        Button("刷新完整资料") { Task { await app.refreshOne(r) } }
        Button("复制 Discogs 链接") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("https://www.discogs.com" + r.discogsURI, forType: .string)
        }
        Divider()
        Button("从本地库删除", role: .destructive) { app.deleteRecord(r) }
    }
}

// MARK: - 网格卡片

struct RecordGridCard: View {
    @EnvironmentObject var app: AppState
    let record: Record
    @State private var hovering = false

    private var isSelected: Bool { app.selectedId == record.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .topTrailing) {
                CachedCover(url: record.coverURL, width: 190, height: 190)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.08),
                                    lineWidth: isSelected ? 2.5 : 1))

                if record.myRating > 0 {
                    HStack(spacing: 1) {
                        ForEach(1...5, id: \.self) { i in
                            Image(systemName: i <= record.myRating ? "star.fill" : "star")
                                .font(.system(size: 7))
                        }
                    }
                    .foregroundStyle(.yellow)
                    .padding(3)
                    .background(Capsule().fill(.black.opacity(0.55)))
                    .padding(4)
                }
            }

            Text(record.title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)

            Text(record.displayArtist)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 4) {
                Text(record.displayYear)
                if !record.country.isEmpty {
                    Text("·").foregroundStyle(.tertiary)
                    Text(record.country)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.10)
                       : (hovering ? Color.primary.opacity(0.05) : Color.clear)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { app.selectedId = record.id }
        .contextMenu {
            Button("刷新完整资料") { Task { await app.refreshOne(record) } }
        }
    }
}

// MARK: - 列表行

struct RecordListRow: View {
    @EnvironmentObject var app: AppState
    let record: Record
    @State private var hovering = false

    private var isSelected: Bool { app.selectedId == record.id }

    var body: some View {
        HStack(spacing: 9) {
            CachedCover(url: record.coverURL, width: 42, height: 42)
            VStack(alignment: .leading, spacing: 1) {
                Text(record.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(record.displayArtist)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(record.displayYear)
                    if !record.country.isEmpty {
                        Text("·").foregroundStyle(.tertiary)
                        Text(record.country)
                    }
                    if !record.genres.isEmpty {
                        Text("·").foregroundStyle(.tertiary)
                        Text(record.genres.prefix(2).joined(separator: ", "))
                    }
                }
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }
            Spacer(minLength: 4)
            if record.myRating > 0 {
                HStack(spacing: 1) {
                    ForEach(1...5, id: \.self) { i in
                        Image(systemName: i <= record.myRating ? "star.fill" : "star")
                            .font(.system(size: 8))
                    }
                }
                .foregroundStyle(.yellow)
            }
            if !record.location.isEmpty {
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .help(record.location)
            }
        }
        .padding(.vertical, 3)
        .listRowBackground(
            isSelected ? Color.accentColor.opacity(0.14)
                       : (hovering ? Color.primary.opacity(0.05) : Color.clear))
        .onHover { hovering = $0 }
    }
}

// MARK: - 简单流式布局（用于筛选标签）

struct FlowTags: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > maxW, x > 0 {
                x = 0; y += rowH + spacing; rowH = 0
            }
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
        return CGSize(width: maxW == .infinity ? x : maxW, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowH + spacing; rowH = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}
