import AppKit
import WebKit
import XCTest
@testable import WorkshopWallpaperBridgeApp

@MainActor
final class LiveWebWallpaperTests: XCTestCase {
    func testOccludedWebAnimationFramesAndCSSTransitionsAdvanceAndPause() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path:"web-clock-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path:"index.html")
        try """
        <style>#tile{width:40px;height:40px;background:red;transition:transform .2s}</style><div id=tile></div>
        <script>window.ticks=0;window.cancelledRan=false;
        const cancelled=requestAnimationFrame(()=>window.cancelledRan=true);cancelAnimationFrame(cancelled);
        function frame(){ticks++;requestAnimationFrame(frame);}requestAnimationFrame(frame);
        setTimeout(()=>document.querySelector('#tile').style.transform='scale(3)',150);</script>
        """.write(to:url,atomically:true,encoding:.utf8)
        let view = RestrictedWebWallpaperView(url:url,readAccessURL:root,frame:CGRect(x:0,y:0,width:600,height:400))
        let window = DesktopWallpaperWindow(contentRect:CGRect(x:-10000,y:-10000,width:600,height:400),styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFrontRegardless()
        defer { view.prepareForClose();window.contentView=nil;window.close() }
        let deadline=Date().addingTimeInterval(5)
        var advanced=false
        while Date()<deadline {
            advanced=(try? await view.webView.evaluateJavaScript("ticks > 5 && document.querySelector('#tile').getBoundingClientRect().width > 110")) as? Bool == true
            if advanced {break}
            try await Task.sleep(for:.milliseconds(40))
        }
        XCTAssertTrue(advanced,"Occluded wallpapers must advance both JavaScript frames and CSS transitions")
        let cancelled = try await view.webView.evaluateJavaScript("cancelledRan") as? Bool
        XCTAssertEqual(cancelled,false)
        view.setPlaybackSuspended(true)
        try await Task.sleep(for:.milliseconds(100))
        let paused = try await view.webView.evaluateJavaScript("ticks") as? Int
        try await Task.sleep(for:.milliseconds(200))
        let stillPaused = try await view.webView.evaluateJavaScript("ticks") as? Int
        XCTAssertEqual(paused,stillPaused)
        view.setPlaybackSuspended(false)
        try await Task.sleep(for:.milliseconds(200))
        let resumed = try await view.webView.evaluateJavaScript("ticks") as? Int
        XCTAssertGreaterThan(try XCTUnwrap(resumed),try XCTUnwrap(paused))
    }

    func testInteractiveWallpaperWindowAcceptsFocusAndMouseMovementOnlyWhileEnabled() {
        let window = DesktopWallpaperWindow(contentRect:CGRect(x:0,y:0,width:100,height:100),styleMask:.borderless,backing:.buffered,defer:true)
        window.isReleasedWhenClosed = false
        defer {window.close()}
        window.setInteractionEnabled(true)
        XCTAssertTrue(window.canBecomeKey)
        XCTAssertTrue(window.acceptsMouseMovedEvents)
        XCTAssertFalse(window.ignoresMouseEvents)
        window.setInteractionEnabled(false)
        XCTAssertFalse(window.canBecomeKey)
        XCTAssertFalse(window.acceptsMouseMovedEvents)
        XCTAssertTrue(window.ignoresMouseEvents)
    }

    func testLocalWebGLClockAndAudioBridgeInActualWebView() async throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path:"Examples/live-web")
        let view = RestrictedWebWallpaperView(url:root.appending(path:"index.html"),readAccessURL:root,frame:CGRect(x:0,y:0,width:960,height:600))
        let window = NSWindow(contentRect:CGRect(x:-10000,y:-10000,width:960,height:600),styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFrontRegardless()
        defer { view.prepareForClose();window.contentView=nil;window.close() }
        let deadline = Date().addingTimeInterval(8)
        var ready = false
        while Date() < deadline {
            ready = (try? await view.webView.evaluateJavaScript("document.querySelector('time')?.textContent?.length > 0")) as? Bool == true
            if ready { break }
            try await Task.sleep(for:.milliseconds(50))
        }
        XCTAssertTrue(ready)
        let result = try await view.webView.callAsyncJavaScript("""
        window.__wwbFrame(Array(128).fill(0.5), [0.5,0.5], true);
        return {webgl:gl.getError()===gl.NO_ERROR, audio:audio.length, level:audio[64], clock:document.querySelector('time').textContent};
        """, in:nil, contentWorld:.page) as? [String:Any]
        XCTAssertEqual(result?["webgl"] as? Bool,true)
        XCTAssertEqual(result?["audio"] as? Int,128)
        XCTAssertEqual(result?["level"] as? Double,0.5)
        XCTAssertFalse((result?["clock"] as? String ?? "").isEmpty)
        let originalValue = try await view.webView.evaluateJavaScript("ry")
        let originalRotation = try XCTUnwrap(originalValue as? Double)
        for (index, type) in [NSEvent.EventType.leftMouseDown, .leftMouseDragged, .leftMouseUp].enumerated() {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with:type,location:CGPoint(x:480 + index * 50,y:300),modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,
                windowNumber:window.windowNumber,context:nil,eventNumber:index,clickCount:1,pressure:1))
            window.sendEvent(event)
            try await Task.sleep(for: .milliseconds(80))
        }
        let draggedValue = try await view.webView.evaluateJavaScript("ry")
        let draggedRotation = try XCTUnwrap(draggedValue as? Double)
        XCTAssertNotEqual(draggedRotation, originalRotation, "Native mouse dragging must rotate the WebGL cube")
        if let output = ProcessInfo.processInfo.environment["WWB_WEB_SNAPSHOT"] {
            let image = try await view.webView.takeSnapshot(configuration:nil)
            let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:URL(filePath:output))
        }
    }
}
