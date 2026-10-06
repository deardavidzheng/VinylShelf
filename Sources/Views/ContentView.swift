import SwiftUI

// MARK: - 主窗口

struct ContentView: View {
    @EnvironmentObject var app: AppState
    @State private var showSettings = false
    @State private var showAdd = false
    @State private var showStats = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            FacetSidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 268, max: 380)
        } content: {
            RecordListPane()
                .navigationSplitViewColumnWidth(min: 340, ideal: 460, max: 620)
        } detail: {
            // 没有选中唱片时详情栏保持空白，不显示占位内容
            if let rec = app.selectedRecord {
                RecordDetailView(record: rec)
                    .id(rec.id)
            }
        }
        .toolbar { toolbarContent }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showAdd) { AddRecordView() }
        .sheet(isPresented: $showStats) { StatsView() }
        .alert("出错了", isPresented: Binding(
            get: { app.dbError != nil },
            set: { if !$0 { app.dbError = nil } })) {
            Button("好") { app.dbError = nil }
        } message: {
            Text(app.dbError ?? "")
        }
        .onAppear {
            // 等 Keychain 后台读取完成再判断，避免误弹设置页
            Task {
                try? await Task.sleep(nanoseconds: 400_000_000)
                if !app.isTokenConfigured || app.totalCount == 0 {
                    showSettings = true
                }
                applyDebugPreset()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showAddSheet)) { _ in
            showAdd = true
        }
        // WKWebView 必须挂在真实窗口层才渲染，用零尺寸 carrier 承载它取封面
        .enableWebImageHosting()
    }

    /// 调试用启动预置：本机没有辅助功能权限，没法注入真实点击去打开「添加」面板，
    /// 只能让面板在启动时自己打开。`VINYLSHELF_OPEN=add`，
    /// 可再用 `VINYLSHELF_PRESET_QUERY` 预填搜索词。正常启动不带这些变量。
    private func applyDebugPreset() {
        let env = ProcessInfo.processInfo.environment
        guard env["VINYLSHELF_OPEN"] == "add" else { return }
        Task { @MainActor in
            showAdd = true
            let q = env["VINYLSHELF_PRESET_QUERY"] ?? ""
            if !q.isEmpty {
                try? await Task.sleep(nanoseconds: 300_000_000)
                await app.searchDiscogs(q, page: 1)
            }
        }
    }

    @ToolbarContentBuilder
    var toolbarContent: some ToolbarContent {        ToolbarItem(placement: .navigation) {
            Button { showSettings = true } label: {
                Label("设置", systemImage: "gearshape")
            }
            .help("设置与 Discogs 同步")
        }

        ToolbarItem(placement: .principal) {
            SyncStatusBar()
        }

        ToolbarItemGroup {
            Button { showAdd = true } label: {
                Label("添加", systemImage: "plus.circle")
            }
            .help("从 Discogs 搜索并添加唱片")

            Button { showStats = true } label: {
                Label("统计", systemImage: "chart.bar.xaxis")
            }
            .help("收藏统计")

            Menu {
                Picker("视图", selection: $app.viewMode) {
                    Label("网格", systemImage: "square.grid.2x2").tag(AppState.ViewMode.grid)
                    Label("列表", systemImage: "list.bullet").tag(AppState.ViewMode.list)
                }
                Divider()
                Picker("排序", selection: $app.sortOrder) {
                    ForEach(AppState.SortOrder.allCases, id: \.self) { o in
                        Text(o.label).tag(o)
                    }
                }
                Divider()
                Button("导出当前筛选为 CSV…") { app.exportCSV() }
            } label: {
                Label("显示选项", systemImage: "line.3.horizontal.decrease.circle")
            }
        }
    }
}

// MARK: - 同步状态条

struct SyncStatusBar: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        HStack(spacing: 10) {
            if app.sync.phase.isRunning {
                ProgressView(value: app.sync.phase.fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 130)
                Text(app.sync.phase.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if case .done(let r) = app.sync.phase {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(r.summary).font(.caption).foregroundStyle(.secondary)
            } else if case .failed(let m) = app.sync.phase {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(m).font(.caption).foregroundStyle(.secondary)
            } else {
                if let d = app.sync.lastSyncDate {
                    Text("上次同步 \(d.formatted(.relative(presentation: .named)))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !app.isTokenConfigured {
                    Text("未配置 Token").font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}

// MARK: - 空状态

/// App 内部广播用的通知名。
/// 放在这里而不是 App 入口文件：无头 harness 编译时会排除 @main 所在的
/// `VinylShelfApp.swift`（否则 @main 冲突），通知名若定义在那里就编不过。
extension Notification.Name {
    static let facetFilterChanged = Notification.Name("vinylshelf.facetFilterChanged")
    static let showAddSheet = Notification.Name("vinylshelf.showAddSheet")
}

struct EmptyDetailView: View {
    var body: some View {
        VStack(spacing: 12) {
            VinylGlyph().frame(width: 96, height: 96)
            Text("选择一张唱片查看详情")
                .font(.headline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
