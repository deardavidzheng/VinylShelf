import SwiftUI

@main
struct VinylShelfApp: App {
    @StateObject private var app = AppState()

    init() {
        // 菜单栏/进程名取自可执行文件名，此处无需设置
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(app)
                .frame(minWidth: 1080, minHeight: 640)
                .onReceive(NotificationCenter.default.publisher(for: .facetFilterChanged)) { _ in
                    app.recomputeFacets()
                }
        }
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {}

            CommandGroup(after: .toolbar) {
                Button("从 Discogs 搜索添加…") {
                    NotificationCenter.default.post(name: .showAddSheet, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
                Button("立即同步") {
                    Task { await app.sync.sync() }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!app.isTokenConfigured)
            }
        }
    }
}
