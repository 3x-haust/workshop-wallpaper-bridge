import AppKit
import WebKit

@MainActor
private final class ClickAcceptingWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
private final class WallpaperGestureObserver: NSObject, WKScriptMessageHandler {
    var receive: ((WKScriptMessage) -> Void)?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) { receive?(message) }
}

@MainActor
final class RestrictedWebWallpaperView: NSView, WKNavigationDelegate, WKUIDelegate, PausableWallpaperContent, WallpaperContentLifecycle {
    private(set) var webView: WKWebView
    private var frameTimer: Timer?
    private var audioConsumer: UUID?
    private var isSuspended = false
    private var closed = false
    private var frameInFlight = false
    private let url: URL
    private let readAccessURL: URL
    private var lastUserGesture = Date.distantPast
    private(set) var pendingExternalURL: URL?
    private var externalLinkBar: NSView?
    var externalURLOpener: (URL) -> Void = { NSWorkspace.shared.open($0) }

    init(url: URL, readAccessURL: URL, frame: CGRect) {
        self.url = url
        self.readAccessURL = readAccessURL
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        // Desktop windows are often considered inactive/occluded by WebKit.
        // Keep wallpaper scripts progressing; our playback controls own pause.
        configuration.preferences.inactiveSchedulingPolicy = .none
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.bridgeSource, injectionTime: .atDocumentStart, forMainFrameOnly: true
        ))
        webView = ClickAcceptingWebView(frame: frame, configuration: configuration)
        super.init(frame: frame)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        let gestureObserver = WallpaperGestureObserver()
        gestureObserver.receive = { [weak self] message in
            guard let self, !self.closed, let source = message.frameInfo.request.url, self.isLocalProjectURL(source) else { return }
            self.lastUserGesture = Date()
        }
        configuration.userContentController.add(gestureObserver, contentWorld:.defaultClient, name:"wallpaperGesture")
        configuration.userContentController.addUserScript(WKUserScript(source:"""
        addEventListener('click', event => {
            if (event.isTrusted) window.webkit.messageHandlers.wallpaperGesture.postMessage(null);
        }, true);
        """,injectionTime:.atDocumentStart,forMainFrameOnly:false,in:.defaultClient))
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
        if let externalLinkBar {
            externalLinkBar.setFrameOrigin(CGPoint(x:12,y:bounds.height-externalLinkBar.frame.height-12))
        }
    }

    func setPlaybackSuspended(_ suspended: Bool) {
        isSuspended = suspended
        webView.configuration.preferences.inactiveSchedulingPolicy = suspended ? .suspend : .none
        webView.callAsyncJavaScript("window.__wwbSetPaused?.(paused);", arguments:["paused":suspended], in:nil, in:.page) { _ in }
        if suspended {
            if let audioConsumer { SystemAudioAnalysis.shared.release(audioConsumer) }
            audioConsumer = nil
        } else if frameTimer != nil, audioConsumer == nil {
            audioConsumer = SystemAudioAnalysis.shared.acquire()
        }
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
        let allowed = targetURL.map(isLocalProjectURL) ?? false
        if !allowed { offerExternalPage(navigationAction) }
        decisionHandler(allowed ? .allow : .cancel)
    }

    private func isLocalProjectURL(_ candidate: URL) -> Bool {
        let root = readAccessURL.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        return candidate.isFileURL && candidate.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(root)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        offerExternalPage(navigationAction)
        return nil
    }

    private func offerExternalPage(_ action: WKNavigationAction) {
        guard !closed, let url = action.request.url, ["https","http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, url.user == nil, url.password == nil,
              action.navigationType == .linkActivated || Date().timeIntervalSince(lastUserGesture) < 1 else { return }
        lastUserGesture = .distantPast
        pendingExternalURL = url
        externalLinkBar?.removeFromSuperview()
        let language = AppLanguage(rawValue: UserDefaults.standard.string(forKey:"language") ?? "") ?? .system
        let button = NSButton(title:String(format:Localization.string("web.openExternal",language:language),host),target:self,action:#selector(openRequestedExternalPage))
        button.bezelStyle = .rounded
        let dismiss = NSButton(title:Localization.string("common.cancel",language:language),target:self,action:#selector(dismissExternalPage))
        let stack = NSStackView(views:[button,dismiss])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top:8,left:8,bottom:8,right:8)
        stack.wantsLayer = true
        stack.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        stack.layer?.cornerRadius = 8
        stack.setFrameSize(stack.fittingSize)
        externalLinkBar = stack
        addSubview(stack)
        needsLayout = true
    }

    @objc func openRequestedExternalPage() {
        guard let pendingExternalURL else { return }
        externalURLOpener(pendingExternalURL)
        dismissExternalPage()
    }

    @objc private func dismissExternalPage() {
        pendingExternalURL = nil
        externalLinkBar?.removeFromSuperview()
        externalLinkBar = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !closed else { return }
        let properties = SceneScriptSession.projectProperties(at: readAccessURL).mapValues { ["value": $0] }
        webView.callAsyncJavaScript(
            "window.wallpaperPropertyListener?.applyUserProperties?.(properties); window.wallpaperPropertyListener?.applyGeneralProperties?.({fps:30}); window.__wwbSetPaused?.(paused);",
            arguments: ["properties": properties, "paused": isSuspended], in: nil, in: .page
        ) { _ in }
        if !isSuspended, audioConsumer == nil { audioConsumer = SystemAudioAnalysis.shared.acquire() }
        frameTimer?.invalidate()
        frameTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sendFrame() }
        }
        if let frameTimer { RunLoop.main.add(frameTimer, forMode: .common) }
    }

    private func sendFrame() {
        guard !closed, !isSuspended, !frameInFlight else { return }
        frameInFlight = true
        let audio = SystemAudioAnalysis.shared.currentSpectrum
        let local = window.map { convert($0.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil) } ?? .zero
        let cursor: [Double] = [Double(local.x / max(1,bounds.width)), Double(1 - local.y / max(1,bounds.height))]
        webView.callAsyncJavaScript("window.__wwbFrame?.(audio, cursor, passive);",
            arguments: ["audio": audio.left + audio.right, "cursor": cursor,
                        "passive": window?.ignoresMouseEvents == true && bounds.contains(local)],
            in: nil, in: .page
        ) { [weak self] _ in self?.frameInFlight = false }
    }

    func prepareForClose() {
        closed = true
        frameTimer?.invalidate()
        frameTimer = nil
        if let audioConsumer { SystemAudioAnalysis.shared.release(audioConsumer) }
        audioConsumer = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName:"wallpaperGesture",contentWorld:.defaultClient)
        dismissExternalPage()
    }

    static let bridgeSource = #"""
    (() => {
        let audioListener, lastX, lastY;
        let paused = false, nextFrameID = 1;
        const nativeRequestFrame = window.requestAnimationFrame.bind(window);
        const nativeCancelFrame = window.cancelAnimationFrame.bind(window);
        const frames = new Map();
        const hiddenAnimations = new Map();
        function runFrame(id, timestamp) {
            const entry = frames.get(id);
            if (!entry || paused) return;
            frames.delete(id);
            entry.callback(timestamp);
        }
        window.requestAnimationFrame = callback => {
            if (typeof callback !== 'function') throw new TypeError('Animation callback must be a function');
            const id = nextFrameID++;
            const entry = {callback, nativeID: null};
            frames.set(id, entry);
            if (!paused) entry.nativeID = nativeRequestFrame(time => runFrame(id, time));
            return id;
        };
        window.cancelAnimationFrame = id => {
            const entry = frames.get(id);
            if (!entry) return;
            if (entry.nativeID !== null) nativeCancelFrame(entry.nativeID);
            frames.delete(id);
        };
        window.__wwbSetPaused = value => {
            paused = !!value;
            hiddenAnimations.clear();
            for (const [id, entry] of frames) {
                if (entry.nativeID !== null) nativeCancelFrame(entry.nativeID);
                entry.nativeID = paused ? null : nativeRequestFrame(time => runFrame(id, time));
            }
            window.wallpaperPropertyListener?.setPaused?.(paused);
        };
        function runHiddenFrames() {
            if (paused || document.visibilityState !== 'hidden') { hiddenAnimations.clear(); return; }
            const timestamp = performance.now();
            // Snapshot before invoking callbacks so frames requested from a
            // callback wait until the next native tick, like browser RAF.
            for (const [id, entry] of Array.from(frames)) {
                if (entry.nativeID !== null) nativeCancelFrame(entry.nativeID);
                try { runFrame(id, timestamp); } catch (error) { console.error(error); }
            }
            // WebKit can also stall the document timeline for CSS transitions
            // in an occluded wallpaper. Advance only clocks that did not move
            // on their own; preserve deliberate pauses, seeks and scroll timelines.
            const active = new Set(document.getAnimations());
            for (const animation of active) {
                if (animation.playState !== 'running' || animation.timeline !== document.timeline) {
                    hiddenAnimations.delete(animation); continue;
                }
                let current = animation.currentTime ?? 0;
                if (typeof current !== 'number') continue;
                const previous = hiddenAnimations.get(animation);
                if (previous && Math.abs(current - previous.time) < 0.01) {
                    current += Math.max(0, timestamp - previous.timestamp) * animation.playbackRate;
                    animation.currentTime = current;
                }
                hiddenAnimations.set(animation, {time:current, timestamp});
            }
            for (const animation of hiddenAnimations.keys()) if (!active.has(animation)) hiddenAnimations.delete(animation);
        }
        window.wallpaperRegisterAudioListener = callback => {
            if (typeof callback !== 'function') throw new TypeError('Audio listener must be a function');
            audioListener = callback;
        };
        window.__wwbFrame = (audio, cursor, passive) => {
            runHiddenFrames();
            if (audioListener) { try { audioListener(audio); } catch (_) {} }
            if (!passive) return;
            const x = cursor[0] * innerWidth, y = cursor[1] * innerHeight;
            if (x === lastX && y === lastY) return;
            const target = document.elementFromPoint(x,y) || document;
            target.dispatchEvent(new MouseEvent('mousemove', {clientX:x, clientY:y, bubbles:true}));
            target.dispatchEvent(new PointerEvent('pointermove', {clientX:x, clientY:y, bubbles:true, pointerId:1, pointerType:'mouse'}));
            lastX=x; lastY=y;
        };
    })();
    """#

    private func installRemoteBlockerAndLoad() {
        let rules = #"""
        [{"trigger":{"url-filter":"^https?://.*"},"action":{"type":"block"}}]
        """#
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "dev.3xhaust.WorkshopWallpaperBridge.BlockRemote",
            encodedContentRuleList: rules
        ) { [weak self] ruleList, error in
            DispatchQueue.main.async {
                guard let self, !self.closed else {
                    return
                }
                guard error == nil, let ruleList else {
                    return
                }
                self.webView.configuration.userContentController.add(ruleList)
                self.webView.loadFileURL(self.url, allowingReadAccessTo: self.readAccessURL)
            }
        }
    }
}
