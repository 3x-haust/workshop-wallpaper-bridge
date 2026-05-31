import AppKit
import WebKit

@MainActor
final class RestrictedWebWallpaperView: NSView, WKNavigationDelegate, PausableWallpaperContent {
    private let webView: WKWebView
    private let url: URL
    private let readAccessURL: URL

    init(url: URL, readAccessURL: URL, frame: CGRect) {
        self.url = url
        self.readAccessURL = readAccessURL
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: frame, configuration: configuration)
        super.init(frame: frame)
        webView.navigationDelegate = self
        addSubview(webView)
        installRemoteBlockerAndLoad()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        webView.frame = bounds
    }

    func setPlaybackSuspended(_ suspended: Bool) {
        webView.isHidden = suspended
        let command = suspended
            ? "document.querySelectorAll('video,audio').forEach((item) => item.pause())"
            : "document.querySelectorAll('video,audio').forEach((item) => item.play().catch(() => {}))"
        webView.evaluateJavaScript(command)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        let targetURL = navigationAction.request.url
        decisionHandler(targetURL?.isFileURL == true ? .allow : .cancel)
    }

    private func installRemoteBlockerAndLoad() {
        let rules = #"""
        [{"trigger":{"url-filter":"^https?://.*"},"action":{"type":"block"}}]
        """#
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "dev.3xhaust.WorkshopWallpaperBridge.BlockRemote",
            encodedContentRuleList: rules
        ) { [weak self] ruleList, _ in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                if let ruleList {
                    self.webView.configuration.userContentController.add(ruleList)
                }
                self.webView.loadFileURL(self.url, allowingReadAccessTo: self.readAccessURL)
            }
        }
    }
}
