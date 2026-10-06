import SwiftUI
import WebKit

/// WKWebView 封面抓取器
///
/// 背景：`i.discogs.com` 由 Cloudflare Bot Management 保护，实测
/// curl / URLSession（无论怎么改 UA、Referer、Cookie、sec-ch-ua）一律 403，
/// 属于 IP 层面的机房流量拦截，客户端侧无法绕过。
/// 但 WKWebView 走的是 WebKit 完整网络栈（含真实 TLS 指纹与 JS 挑战），
/// 与 Safari 同源，命中率高得多。
///
/// 策略：内存复用同一个 WKWebView，通过 JS 探测图片是否加载成功，
/// 成功后从 canvas 取回 base64 数据。用完即销毁，避免长期占用内存。
@MainActor
final class WebImageLoader: NSObject, ObservableObject {
    static let shared = WebImageLoader()

    private var webView: WKWebView?
    private var pending: [(url: String, resolve: (Data?) -> Void)] = []
    private var currentIndex = 0
    private var loadTimeout: Task<Void, Never>?

    /// 统计：命中 / 失败，用于设置页显示
    @Published private(set) var attempts = 0
    @Published private(set) var successes = 0

    private func ensureWebView() -> WKWebView {
        if let w = webView { return w }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()   // 不留 cookie 缓存
        let w = WKWebView(frame: .zero, configuration: config)
        w.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        // 隐藏但必须加入窗口层级，WKWebView 离屏不渲染会拿不到 canvas
        w.frame = CGRect(x: 0, y: 0, width: 2, height: 2)
        w.setValue(0.01, forKey: "alphaValue")   // KVC 绕过 Swift 封装缺失的属性
        webView = w
        return w
    }

    /// 用 WebView 抓取单张图片
    func fetch(_ urlString: String) async -> Data? {
        guard !urlString.isEmpty else { return nil }
        return await withCheckedContinuation { cont in
            pending.append((urlString, { cont.resume(returning: $0) }))
            if pending.count == 1 { startNext() }
        }
    }

    private func startNext() {
        guard currentIndex < pending.count else {
            pending.removeAll()
            currentIndex = 0
            return
        }
        let item = pending[currentIndex]
        attempts += 1

        loadTimeout?.cancel()
        loadTimeout = Task { [weak self] in
            // 4s 超时：窗口被 sheet 遮挡时 WKWebView 会暂停渲染，
            // 15s 会让每张图都拖成整列空白。现在 URLSession 是主通道，这里只是降级。
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.finishCurrent(nil)
        }

        let html = """
        <html><body style="margin:0;background:#fff">
        <img id="t" src="\(item.url)" crossorigin="anonymous" style="display:block">
        <script>
        const img = document.getElementById('t');
        function report(ok, data) {
          try { window.webkit.messageHandlers.bridge.postMessage({ok: ok, data: data || ''}); }
          catch(e) {}
        }
        img.onload = function() {
          try {
            const c = document.createElement('canvas');
            c.width = img.naturalWidth; c.height = img.naturalHeight;
            c.getContext('2d').drawImage(img, 0, 0);
            report(true, c.toDataURL('image/jpeg', 0.9));
          } catch(e) { report(false); }
        };
        img.onerror = function() { report(false); };
        setTimeout(function(){ report(false); }, 3500);
        </script></body></html>
        """

        ensureWebView().loadHTMLString(html, baseURL: URL(string: "https://www.discogs.com/"))
    }

    /// 由 WKScriptMessageHandler 调用
    nonisolated func handleMessage(_ body: Any) {
        guard let dict = body as? [String: Any] else { return }
        let ok = (dict["ok"] as? Bool) ?? false
        let dataStr = (dict["data"] as? String) ?? ""
        var data: Data?
        if ok, let comma = dataStr.firstIndex(of: ",") {
            let b64 = String(dataStr[dataStr.index(after: comma)...])
            data = Data(base64Encoded: b64)
        }
        Task { @MainActor in
            await finishCurrent(data)
        }
    }

    @MainActor
    private func finishCurrent(_ data: Data?) {
        loadTimeout?.cancel()
        loadTimeout = nil
        if data != nil { successes += 1 }
        guard currentIndex < pending.count else { return }
        let cb = pending[currentIndex].resolve
        currentIndex += 1
        if currentIndex < pending.count {
            startNext()
        } else {
            pending.removeAll()
            currentIndex = 0
        }
        cb(data)
    }

    var stats: String { "WebView 取图 \(successes)/\(attempts) 成功" }
}

// MARK: - 消息桥

private class BridgeHandler: NSObject, WKScriptMessageHandler {
    weak var owner: WebImageLoader?
    init(owner: WebImageLoader) { self.owner = owner }

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        Task { @MainActor in
            WebImageLoader.shared.handleMessage(m.body)
        }
    }
}

// MARK: - 挂载 WebView 到窗口

/// WKWebView 离屏不会渲染，必须挂在真实窗口上才能加载图片。
/// 用一个零尺寸的 overlay 承载它。
struct WebImageHost: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                WebViewCarrier()
                    .frame(width: 0, height: 0)
                    .opacity(0.01)
            )
    }
}

struct WebViewCarrier: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: .zero)
        let wv = WebImageLoader.shared.ensureWebViewForHost()
        wv.frame = CGRect(x: 0, y: 0, width: 2, height: 2)
        container.addSubview(wv)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension WebImageLoader {
    func ensureWebViewForHost() -> WKWebView {
        let w = ensureWebView()
        if w.navigationDelegate == nil {
            w.navigationDelegate = WebNavDelegate()
            let c = WKUserContentController()
            c.add(BridgeHandler(owner: self), name: "bridge")
            w.configuration.userContentController = c
        }
        return w
    }
}

class WebNavDelegate: NSObject, WKNavigationDelegate {
    func webView(_ w: WKWebView, didFail navigation: WKNavigation!, withError e: Error) {
        Task { @MainActor in WebImageLoader.shared.handleMessage(["ok": false]) }
    }
    func webView(_ w: WKWebView, didFailProvisionalNavigation nav: WKNavigation!, withError e: Error) {
        Task { @MainActor in WebImageLoader.shared.handleMessage(["ok": false]) }
    }
}

extension View {
    func enableWebImageHosting() -> some View {
        modifier(WebImageHost())
    }
}
