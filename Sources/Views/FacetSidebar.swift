import SwiftUI

/// 侧栏：多维 facet 多选
struct FacetSidebar: View {
    @EnvironmentObject var app: AppState
    @State private var expanded: Set<FacetDimension> = [.genre, .decade, .country]
    @State private var searchInDimension: String = ""

    /// 侧栏展示顺序：先内容维度（流派/风格/年代/国家/艺人），再属性维度，最后本地字段
    static let order: [FacetDimension] = [
        .genre, .style, .decade, .country, .artist,
        .label, .format,
        .condition, .statusLocal, .tag, .folder
    ]

    /// 维度取值的显示名。**筛选仍按原始值进行**，这里只影响 UI 上显示的文字，
    /// 否则用户会看到 `folder_1` / `owned` 这种内部字段名。
    static func displayLabel(_ dim: FacetDimension, _ value: String) -> String {
        switch dim {
        case .folder:
            switch value {
            case "folder_0": return "全部 All"
            case "folder_1": return "未分类 Uncategorized"
            default: return "文件夹 \(value.replacingOccurrences(of: "folder_", with: ""))"
            }
        case .statusLocal:
            switch value {
            case "owned": return "已收藏"
            case "wanted": return "想拥有"
            case "sold": return "已出售"
            default: return value
            }
        default:
            return value
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(FacetSidebar.order) { dim in
                        FacetSection(
                            dim: dim,
                            counts: app.facetCounts[dim.rawValue] ?? [:],
                            isExpanded: expanded.contains(dim),
                            filter: $app.filter
                        ) {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                if expanded.contains(dim) { expanded.remove(dim) } else { expanded.insert(dim) }
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            if !app.filter.isEmpty {
                Divider()
                activeFilterBar
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("我的黑胶库")
                    .font(.headline)
                Spacer()
                Text("\(app.filteredCount)")
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if !app.isTokenConfigured {
                Label("未连接 Discogs", systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange)
            } else if !app.sync.username.isEmpty {
                Label(app.sync.username, systemImage: "person.crop.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var activeFilterBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("已启用 \(app.filter.activeDimensionCount) 个维度")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("全部清除") {
                    withAnimation { app.filter.clearAll() }
                    app.recomputeFacets()
                }
                .buttonStyle(.link).font(.caption)
            }
            FlowTags {
                ForEach(Array(app.filter.selections.keys), id: \.self) { dimRaw in
                    if let dim = FacetDimension(rawValue: dimRaw),
                       let selected = app.filter.selections[dimRaw], !selected.isEmpty {
                        ForEach(selected.sorted(), id: \.self) { v in
                            FilterChip(text: FacetSidebar.displayLabel(dim, v)) {
                                withAnimation {
                                    app.filter.toggle(dimension: dim, value: v)
                                    app.recomputeFacets()
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - 单个 facet 分区

struct FacetSection: View {
    let dim: FacetDimension
    let counts: [String: Int]
    let isExpanded: Bool
    @Binding var filter: FacetFilter
    let onToggle: () -> Void

    @State private var showAll = false
    @State private var keyword = ""

    /// 值太多时只显示前 N 个
    private var displayLimit: Int { showAll ? 500 : 12 }

    private var visible: [(String, Int)] {
        var items: [(String, Int)] = []
        if dim == .decade {
            // 年代按时间正序更符合直觉（1950s → 2020s），未知排最后
            items = counts.sorted { a, b in
                let av = Int(a.0.prefix(4)) ?? 9999
                let bv = Int(b.0.prefix(4)) ?? 9999
                if av != bv { return av < bv }
                return a.0 < b.0
            }
        } else {
            items = counts.sorted { a, b in
                if a.value != b.value { return a.value > b.value }
                return a.key.localizedStandardCompare(b.key) == .orderedAscending
            }
        }
        if !keyword.trimmed.isEmpty {
            let k = keyword.trimmed.lowercased()
            items = items.filter { $0.0.lowercased().contains(k) }
        }
        // ⚠️ 已选中的值必须始终可见：它在排序里可能排在 top-N 之外
        // （国家 29 个值、厂牌几百个，低频值很容易被截掉）。
        // 一旦「选中后才消失」，看起来就像该维度不支持多选。
        let sel = selectedValues
        let limit = showAll ? 500 : displayLimit
        var shown = Array(items.prefix(limit))
        if !sel.isEmpty {
            let shownKeys = Set(shown.map(\.0))
            shown.append(contentsOf: items.filter { sel.contains($0.0) && !shownKeys.contains($0.0) })
        }
        return shown
    }

    private var selectedValues: Set<String> {
        filter.selections[dim.rawValue] ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Image(systemName: dim.systemImage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                    Text(dim.displayName)
                        .font(.system(size: 12, weight: .semibold))
                    if !selectedValues.isEmpty {
                        Text("\(selectedValues.count)")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Capsule().fill(.tint))
                            .foregroundStyle(.white)
                    }
                    Spacer()
                    Text("\(counts.count)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)

            if isExpanded {
                if counts.isEmpty {
                    // 没有任何记录在该维度上有取值（如还没设过自定义标签）。
                    // 直接空白会让人以为是 bug，明确说明。
                    Text("该维度暂无取值")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                        .padding(.leading, 26).padding(.vertical, 3)
                } else {
                    if counts.count > 14 {
                        TextField("筛选 \(dim.displayName)…", text: $keyword)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))
                            .padding(.horizontal, 10)
                            .padding(.bottom, 4)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(visible, id: \.0) { value, count in
                            FacetRow(
                                displayLabel: FacetSidebar.displayLabel(dim, value),
                                value: value,
                                count: count,
                                selected: selectedValues.contains(value),
                                dim: dim,
                                filter: $filter
                            )
                        }
                        if counts.count > displayLimit && !showAll {
                            Button("显示全部 \(counts.count) 项") {
                                showAll = true
                            }
                            .buttonStyle(.link)
                            .font(.system(size: 11))
                            .padding(.leading, 26)
                            .padding(.vertical, 3)
                        }
                        if showAll && counts.count > 14 {
                            Button("收起") { showAll = false }
                                .buttonStyle(.link)
                                .font(.system(size: 11))
                                .padding(.leading, 26)
                                .padding(.vertical, 3)
                        }
                        if visible.isEmpty && !keyword.isEmpty {
                            Text("无匹配项")
                                .font(.system(size: 11)).foregroundStyle(.tertiary)
                                .padding(.leading, 26).padding(.vertical, 3)
                        }
                    }
                }
            }
        }
    }
}

struct FacetRow: View {
    let displayLabel: String          // 展示用（可中文化）
    let value: String                 // 筛选用（原始值）
    let count: Int
    let selected: Bool
    let dim: FacetDimension
    @Binding var filter: FacetFilter

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.12)) {
                filter.toggle(dimension: dim, value: value)
            }
            // 通知 AppState 重算（facet 恒为全库口径，主要驱动中间栏列表刷新）
            NotificationCenter.default.post(name: .facetFilterChanged, object: nil)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.5))
                Text(displayLabel)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .foregroundStyle(selected ? Color.primary : Color.primary)
                Spacer(minLength: 4)
                Text("\(count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 22)
        .padding(.trailing, 10)
        .padding(.vertical, 2.5)
        .background(selected ? Color.accentColor.opacity(0.10) : Color.clear)
    }
}

struct FilterChip: View {
    let text: String
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 3) {
            Text(text).font(.system(size: 10))
            Image(systemName: "xmark")
                .font(.system(size: 7, weight: .bold))
                .opacity(hovering ? 1 : 0.55)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(Capsule().fill(Color.accentColor.opacity(hovering ? 0.28 : 0.16)))
        .foregroundStyle(Color.accentColor)
        .onHover { hovering = $0 }
        .onTapGesture(perform: onRemove)
    }
}
