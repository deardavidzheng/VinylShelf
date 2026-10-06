import SwiftUI

/// 右栏：完整详情（Discogs 数据 + 本地字段）
struct RecordDetailView: View {
    @EnvironmentObject var app: AppState
    let record: Record

    @State private var showGallery = false
    @State private var editing = false
    @State private var galleryIndex = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                headerBlock
                Divider()
                metaBlock
                if !record.tracklist.isEmpty { trackBlock }
                if !record.credits.isEmpty { creditsBlock }
                if !record.companies.isEmpty { companiesBlock }
                if !record.identifiers.isEmpty { identifiersBlock }
                if !record.notes.isEmpty { notesBlock }
                localBlock
                if !record.discogsURI.isEmpty { linkBlock }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear { Task { await app.ensureCover(for: record) } }
        .sheet(isPresented: $editing) { EditLocalFields(record: record) }
        .sheet(isPresented: $showGallery) { GalleryView(record: record, index: galleryIndex) }
    }

    // MARK: 头部

    private var headerBlock: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack(alignment: .bottomTrailing) {
                CachedCover(url: record.coverURL, width: 190, height: 190)
                if record.gallery.count > 1 {
                    Button {
                        galleryIndex = 0
                        showGallery = true
                    } label: {
                        Label("\(record.gallery.count)", systemImage: "photo.on.rectangle")
                            .font(.system(size: 9))
                            .padding(3).padding(.horizontal, 5)
                            .background(Capsule().fill(.black.opacity(0.65)))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .padding(4)
                    .help("查看全部 \(record.gallery.count) 张图片")
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(record.artist.isEmpty ? "未知艺人" : record.artist)
                    .font(.title3.weight(.semibold))
                Text(record.title)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 5) {
                    TagPill(text: record.displayYear, icon: "calendar")
                    TagPill(text: record.displayCountry, icon: "globe")
                    if record.discogsRating > 0 {
                        TagPill(text: String(format: "%.2f ★", record.discogsRating),
                                icon: "star.fill", tint: .orange)
                        TagPill(text: "\(record.discogsRatingCount) 人评", icon: "person.2")
                    }
                }
                .padding(.top, 2)

                if !record.formatSummary.isEmpty {
                    Text(record.formatSummary)
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.top, 1)
                }
                HStack(spacing: 6) {
                    TagPill(text: "持有 \(record.haveCount)", icon: "square.stack.3d.up")
                    TagPill(text: "想要 \(record.wantCount)", icon: "hand.thumbsup")
                    if let w = record.estimatedWeight {
                        TagPill(text: "\(w) g", icon: "scalemass")
                    }
                    if let p = record.lowestPrice, p > 0 {
                        TagPill(text: String(format: "$%.2f", p), icon: "dollarsign.circle")
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(18)
    }

    // MARK: 基本信息

    private var metaBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !record.labels.isEmpty {
                MetaRow(label: "厂牌") {
                    WrappedTags(tags: record.labels)
                }
            }
            if !record.catnos.isEmpty {
                MetaRow(label: "目录号") {
                    Text(record.catnos.joined(separator: " / "))
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            if !record.genres.isEmpty {
                MetaRow(label: "流派") { WrappedTags(tags: record.genres, tint: .blue) }
            }
            if !record.styles.isEmpty {
                MetaRow(label: "风格") { WrappedTags(tags: record.styles, tint: .purple) }
            }
            if !record.series.isEmpty {
                MetaRow(label: "系列") { WrappedTags(tags: record.series, tint: .teal) }
            }
            MetaRow(label: "发行时间") {
                Text(record.releasedFormatted.nilIfEmpty ?? record.released.nilIfEmpty ?? "—")
                    .font(.system(size: 11))
            }
            if record.discogsRatingCount > 0 {
                MetaRow(label: "社区评分") {
                    HStack(spacing: 3) {
                        ForEach(1...5, id: \.self) { i in
                            Image(systemName: Double(i) <= record.discogsRating.rounded() ? "star.fill" : "star")
                                .font(.system(size: 10))
                        }
                        Text(String(format: "%.2f", record.discogsRating))
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(.orange)
                }
            }
            if record.discogsReleaseId > 0 {
                MetaRow(label: "Discogs") {
                    HStack(spacing: 8) {
                        Text("Release #\(record.discogsReleaseId)")
                            .font(.system(size: 11, design: .monospaced))
                        if !record.dateChangedOnDiscogs.isEmpty {
                            Text("更新于 " + record.dateChangedOnDiscogs.prefix(10))
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        if !record.dataQuality.isEmpty {
                            TagPill(text: record.dataQuality,
                                    icon: record.dataQuality == "Correct" ? "checkmark.seal.fill" : "exclamationmark.triangle",
                                    tint: record.dataQuality == "Correct" ? .green : .orange)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
    }

    // MARK: 曲目

    private var trackBlock: some View {
        Section {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(record.tracklist.enumerated()), id: \.offset) { _, t in
                    if t.isHeading {
                        Text(t.title)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .padding(.top, 8).padding(.bottom, 3)
                    } else {
                        HStack(alignment: .top, spacing: 8) {
                            Text(t.position)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .frame(width: 30, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(t.title)
                                    .font(.system(size: 12))
                                    .fixedSize(horizontal: false, vertical: true)
                                if !t.credits.isEmpty {
                                    Text(t.credits.map { "\($0.role): \($0.name)" }.joined(separator: " · "))
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            Spacer(minLength: 4)
                            Text(t.durationDisplay)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2.5)
                    }
                }
            }
        } header: {
            SectionHeader(title: "曲目表", count: record.realTrackCount)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
    }

    // MARK: 制作人员

    private var creditsBlock: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(record.creditsByRole, id: \.role) { group in
                    HStack(alignment: .top, spacing: 8) {
                        Text(group.role)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 92, alignment: .leading)
                        WrappedTags(tags: group.people.map { c in
                            c.displayName + (c.tracksDisplay.isEmpty ? "" : " (\(c.tracksDisplay))")
                        })
                        Spacer(minLength: 0)
                    }
                }
            }
        } header: {
            SectionHeader(title: "制作人员", count: record.credits.count)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
    }

    // MARK: 厂商

    private var companiesBlock: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(record.companiesByType, id: \.type) { group in
                    HStack(alignment: .top, spacing: 8) {
                        Text(group.type)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 92, alignment: .leading)
                        WrappedTags(tags: group.items.map { c in
                            c.catno.isEmpty ? c.name : "\(c.name) [\(c.catno)]"
                        }, tint: .teal)
                        Spacer(minLength: 0)
                    }
                }
            }
        } header: {
            SectionHeader(title: "参与公司", count: record.companies.count)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
    }

    // MARK: 编号

    private var identifiersBlock: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(record.identifiersByType, id: \.type) { group in
                    HStack(alignment: .top, spacing: 8) {
                        Text(group.type)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 92, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(group.items, id: \.self) { item in
                                Text(item.value)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .textSelection(.enabled)
                                if !item.description.isEmpty {
                                    Text(item.description)
                                        .font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        } header: {
            SectionHeader(title: "编号体系", count: record.identifiers.count)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
    }

    // MARK: 备注

    private var notesBlock: some View {
        Section {
            Text(record.notes)
                .font(.system(size: 11))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } header: {
            SectionHeader(title: "Discogs 备注", count: 0)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
    }

    // MARK: 本地字段

    private var localBlock: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("我的评分").font(.system(size: 10)).foregroundStyle(.secondary)
                        StarPicker(rating: Binding(
                            get: { record.myRating },
                            set: { v in app.updateLocal(record, rating: v) }))
                    }
                    Spacer()
                }

                if !record.condition.isEmpty || !record.location.isEmpty || !record.tags.isEmpty {
                    HStack(spacing: 6) {
                        if !record.condition.isEmpty {
                            TagPill(text: record.condition, icon: "sparkles", tint: .green)
                        }
                        if !record.location.isEmpty {
                            TagPill(text: record.location, icon: "mappin.and.ellipse", tint: .blue)
                        }
                        ForEach(record.tags, id: \.self) { t in
                            TagPill(text: t, icon: "bookmark", tint: .orange)
                        }
                    }
                }

                if !record.myNotes.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("我的笔记").font(.system(size: 10)).foregroundStyle(.secondary)
                        Text(record.myNotes)
                            .font(.system(size: 11))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack {
                    Text("加入本地：\(record.dateAddedLocal.prefix(10))")
                        .font(.system(size: 9.5)).foregroundStyle(.tertiary)
                    Spacer()
                    Button("编辑本地信息…") { editing = true }
                        .buttonStyle(.link).font(.caption)
                }
            }
        } header: {
            SectionHeader(title: "本地信息", count: 0)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
    }

    // MARK: 链接

    private var linkBlock: some View {
        HStack(spacing: 12) {
            Button {
                Task { await app.refreshOne(record) }
            } label: {
                Label("从 Discogs 刷新资料", systemImage: "arrow.clockwise")
                    .font(.system(size: 11))
            }
            .buttonStyle(.bordered)

            if record.discogsReleaseId > 0 {
                Link(destination: URL(string: "https://www.discogs.com" + record.discogsURI)!) {
                    Label("在 Discogs 打开", systemImage: "arrow.up.right.square")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 20)
    }
}

// MARK: - 小组件

struct SectionHeader: View {
    let title: String
    let count: Int
    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.primary)
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.18)))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.top, 4)
        .padding(.bottom, 6)
    }
}

struct MetaRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            content
            Spacer(minLength: 0)
        }
    }
}

struct TagPill: View {
    let text: String
    var icon: String? = nil
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 3) {
            if let icon { Image(systemName: icon).font(.system(size: 8)) }
            Text(text).font(.system(size: 9.5))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(Capsule().fill(tint.opacity(0.14)))
        .foregroundStyle(tint)
    }
}

/// 自动换行的标签流
struct WrappedTags: View {
    let tags: [String]
    var tint: Color = .secondary

    var body: some View {
        FlowTags(spacing: 4) {
            ForEach(tags, id: \.self) { t in
                Text(t)
                    .font(.system(size: 9.5))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(RoundedRectangle(cornerRadius: 4)
                        .fill(tint.opacity(0.13)))
                    .foregroundStyle(tint)
            }
        }
    }
}

struct StarPicker: View {
    @Binding var rating: Int
    @State private var hover: Int = 0

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { i in
                Image(systemName: i <= (hover > 0 ? hover : rating) ? "star.fill" : "star")
                    .font(.system(size: 15))
                    .foregroundStyle(i <= (hover > 0 ? hover : rating) ? .yellow : .secondary.opacity(0.45))
                    .onHover { hover = $0 ? i : 0 }
                    .onTapGesture { rating = (rating == i) ? 0 : i }
            }
            if rating > 0 {
                Button {
                    rating = 0
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - 图集

struct GalleryView: View {
    let record: Record
    @State var index: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            if index < record.gallery.count {
                AsyncCover(url: record.gallery[index].uri)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 560)
            }
            HStack {
                Button { index = max(0, index - 1) } label: {
                    Image(systemName: "chevron.left").font(.title3)
                }
                .disabled(index == 0)
                Text("\(index + 1) / \(record.gallery.count)")
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 70)
                Button { index = min(record.gallery.count - 1, index + 1) } label: {
                    Image(systemName: "chevron.right").font(.title3)
                }
                .disabled(index >= record.gallery.count - 1)
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(.bottom, 10)
        }
        .padding(16)
        .frame(width: 700, height: 660)
    }
}

/// 详情页大图：优先本地缓存，miss 时下载
struct AsyncCover: View {
    let url: String
    @EnvironmentObject var app: AppState
    @State private var image: NSImage?
    @State private var tried = false

    var body: some View {
        Group {
            if let image = image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.12))
                    if tried {
                        VinylGlyph().frame(width: 70, height: 70).opacity(0.4)
                    } else {
                        ProgressView()
                    }
                }
            }
        }
        .task(id: url) {
            guard !url.isEmpty else { tried = true; return }
            if let hit = ImageCache.shared.image(for: url) { image = hit; return }
            let dest = ImageCache.shared.diskPath(for: url)
            // 先试 WebView（能过 Cloudflare），失败再降级 URLSession
            if let data = await WebImageLoader.shared.fetch(url), !data.isEmpty,
               (try? data.write(to: dest, options: .atomic)) != nil,
               let img = NSImage(contentsOf: dest) {
                image = img
            } else if let bytes = await app.client.downloadImage(urlString: url, to: dest),
                      bytes > 0, let img = NSImage(contentsOf: dest) {
                image = img
            } else {
                tried = true
            }
        }
    }
}

// MARK: - 编辑本地字段

struct EditLocalFields: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    let record: Record

    @State private var rating: Int = 0
    @State private var notes: String = ""
    @State private var tags: String = ""
    @State private var location: String = ""
    @State private var condition: String = ""
    @State private var statusLocal: String = "owned"

    private let conditions = ["M", "NM", "NM-", "VG+", "VG", "G+", "G", "G-", "P"]
    private let statuses = [("owned", "已拥有"), ("wanted", "想入手"), ("sold", "已出售")]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("编辑本地信息").font(.headline)
            Text(record.title).font(.caption).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("我的评分").font(.caption)
                StarPicker(rating: $rating)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("品相").font(.caption)
                Picker("", selection: $condition) {
                    Text("未标注").tag("")
                    ForEach(conditions, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().pickerStyle(.menu).frame(width: 120)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("存放位置").font(.caption)
                TextField("如：A架-2层-左3", text: $location).textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("自定义标签（逗号分隔）").font(.caption)
                TextField("如：爵士, 现场版, 常听", text: $tags).textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("收藏状态").font(.caption)
                Picker("", selection: $statusLocal) {
                    ForEach(statuses, id: \.0) { Text($1).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 260)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("我的笔记").font(.caption)
                TextEditor(text: $notes)
                    .frame(height: 100)
                    .font(.system(size: 12))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    let parsed = tags.split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    app.updateLocal(record, rating: rating, notes: notes,
                                    tags: parsed, location: location,
                                    condition: condition, statusLocal: statusLocal)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear {
            rating = record.myRating
            notes = record.myNotes
            tags = record.tags.joined(separator: ", ")
            location = record.location
            condition = record.condition
            statusLocal = record.statusLocal.isEmpty ? "owned" : record.statusLocal
        }
    }
}
