import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var tokenInput = ""
    @State private var showToken = false
    @State private var verifyMessage = ""
    @State private var verifying = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("设置").font(.headline)
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // ---- Discogs 连接 ----
                    group("Discogs 连接") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                if app.isTokenConfigured {
                                    Label("已连接", systemImage: "checkmark.circle.fill")
                                        .foregroundStyle(.green).font(.callout)
                                    if !app.sync.username.isEmpty {
                                        Text("账号：\(app.sync.username)")
                                            .font(.callout).foregroundStyle(.secondary)
                                    }
                                } else {
                                    Label("未连接", systemImage: "exclamationmark.circle")
                                        .foregroundStyle(.orange).font(.callout)
                                }
                                Spacer()
                            }

                            Text("Discogs 已停用账号密码直接连接，需使用 Personal Access Token。")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            Text("获取方式")
                                .font(.caption.weight(.semibold))
                            Text("1. 登录 discogs.com\n2. 打开 Settings → Developers\n3. 点击 Personal Access Tokens 旁的「Generate new token」\n4. 复制生成的字符串粘贴到下方")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)

                            HStack {
                                Group {
                                    if showToken {
                                        TextField("粘贴 Token", text: $tokenInput)
                                            .textFieldStyle(.roundedBorder)
                                            .font(.system(size: 11, design: .monospaced))
                                    } else {
                                        SecureField("粘贴 Token", text: $tokenInput)
                                            .textFieldStyle(.roundedBorder)
                                            .font(.system(size: 11))
                                    }
                                }
                                Button {
                                    showToken.toggle()
                                } label: {
                                    Image(systemName: showToken ? "eye.slash" : "eye")
                                }
                                .buttonStyle(.bordered)
                            }

                            HStack {
                                Button("保存并验证") {
                                    app.saveToken(tokenInput)
                                    tokenInput = ""
                                    Task { await verify() }
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(tokenInput.trimmed.isEmpty)

                                if verifying {
                                    ProgressView().controlSize(.small)
                                } else if !verifyMessage.isEmpty {
                                    Text(verifyMessage)
                                        .font(.caption)
                                        .foregroundStyle(verifyMessage.contains("✓") ? .green : .red)
                                }
                                Spacer()
                            }

                            if app.isTokenConfigured {
                                Button("清除 Token", role: .destructive) {
                                    app.clearToken()
                                    verifyMessage = ""
                                }
                                .buttonStyle(.link)
                            }
                        }
                    }

                    // ---- 同步 ----
                    group("同步") {
                        VStack(alignment: .leading, spacing: 10) {
                            if let d = app.sync.lastSyncDate {
                                HStack {
                                    Text("上次同步")
                                    Spacer()
                                    Text(d.formatted(date: .abbreviated, time: .shortened))
                                        .foregroundStyle(.secondary)
                                }
                                .font(.callout)
                            }
                            if app.sync.rateLimitRemaining >= 0 {
                                HStack {
                                    Text("API 剩余额度")
                                    Spacer()
                                    Text("\(app.sync.rateLimitRemaining)/60 每分钟")
                                        .foregroundStyle(.secondary)
                                        .font(.system(size: 11, design: .monospaced))
                                }
                                .font(.callout)
                            }

                            if app.sync.phase.isRunning {
                                ProgressView(value: app.sync.phase.fraction)
                                    .progressViewStyle(.linear)
                                Text(app.sync.phase.label)
                                    .font(.caption).foregroundStyle(.secondary)
                                Button("取消同步", role: .destructive) { app.sync.cancel() }
                                    .buttonStyle(.bordered)
                            } else {
                                HStack {
                                    Button("立即同步（增量）") {
                                        Task { await app.sync.sync(forceFullDetail: false) }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(!app.isTokenConfigured)

                                    Button("全量重建") {
                                        Task { await app.sync.sync(forceFullDetail: true) }
                                    }
                                    .disabled(!app.isTokenConfigured)
                                    .help("忽略指纹，重新拉取所有详情（约 5 分钟）")
                                    Spacer()
                                }
                            }

                            Text("增量同步原理：Discogs 收藏接口不返回「最后更新时间」，因此本地为每条记录保存字段指纹；同步时只对指纹变化的条目请求完整详情，299 张通常只需 3 个请求。")
                                .font(.caption).foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)

                            if let err = app.sync.phase.errorMessage {
                                Text(err).font(.caption).foregroundStyle(.red)
                            }
                        }
                    }

                    // ---- 本地 → Discogs 写回 ----
                    group("写入 Discogs") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Button("导入 Discogs 想读单") {
                                    Task { await app.importDiscogsWantlist() }
                                }
                                .buttonStyle(.bordered)
                                .disabled(!app.isTokenConfigured || app.isPushing)

                                if app.pendingPushCount > 0 {
                                    Button("推送 \(app.pendingPushCount) 条到 Discogs 收藏") {
                                        Task { await app.pushPendingToDiscogs() }
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(app.isPushing)
                                    .help("这些是本地新增、尚未进入 Discogs 收藏的唱片")
                                }
                                if app.isPushing {
                                    ProgressView().controlSize(.small)
                                    Text(app.pushProgress).font(.caption).foregroundStyle(.secondary)
                                }
                            }

                            if app.pendingPushCount > 0 {
                                Text("有 \(app.pendingPushCount) 条本地新增的唱片还没进 Discogs 收藏。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }

                            // Discogs 的能力边界，必须如实告知，不能做成一个删不掉的按钮
                            Label(PushEngine.removalNotice, systemImage: "info.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    // ---- 本地库 ----
                    group("本地库") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("数据库")
                                Spacer()
                                Text(AppPaths.database.path)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .font(.caption)

                            HStack {
                                Text("封面缓存")
                                Spacer()
                                Text(ByteCountFormatter.string(
                                    fromByteCount: Int64(app.imageCache.diskUsage()),
                                    countStyle: .file))
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption)

                            HStack(spacing: 8) {
                                Button("下载全部封面") {
                                    Task { await app.downloadAllCovers() }
                                }
                                .buttonStyle(.bordered)
                                if app.coverTaskRunning {
                                    ProgressView().controlSize(.small)
                                    Text(app.coverProgress).font(.caption).foregroundStyle(.secondary)
                                }
                            }

                            Text("Discogs 图片 CDN 对非浏览器请求返回 403，App 改用内置 WebView 抓取，因此需要联网且首次较慢。抓取后本地缓存，之后离线可用。")
                                .font(.caption).foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)

                            HStack {
                                Button("在访达中显示") {
                                    NSWorkspace.shared.activateFileViewerSelecting([AppPaths.database])
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }

                    // ---- 同步日志 ----
                    if !app.sync.log.isEmpty {
                        group("同步日志") {
                            ScrollView {
                                Text(app.sync.log.suffix(40).joined(separator: "\n"))
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(height: 130)
                            .background(Color.secondary.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                        }
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 560, height: 620)
        .onAppear {
            // 已保存的 token 不回填到输入框（避免明文显示在屏幕上）；
            // 用户想更换时直接粘贴新的覆盖即可。
            tokenInput = ""
        }
    }

    @ViewBuilder
    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func verify() async {
        verifying = true
        defer { verifying = false }
        do {
            let id = try await app.client.identity()
            await MainActor.run {
                app.sync.username = id.username ?? ""
                verifyMessage = "✓ 验证成功，账号 \(id.username ?? "")"
            }
        } catch {
            await MainActor.run { verifyMessage = "✗ \(error.localizedDescription)" }
        }
    }
}

extension SyncEngine.Phase {
    var errorMessage: String? {
        if case .failed(let m) = self { return m }
        return nil
    }
}
