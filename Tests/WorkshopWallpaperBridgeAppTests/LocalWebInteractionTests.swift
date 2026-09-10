import AppKit
import WebKit
import XCTest
@testable import WorkshopWallpaperBridgeApp

/// Optional integration coverage against user-owned local projects. No creator
/// assets or source code are copied into this repository or test fixtures.
@MainActor
final class LocalWebInteractionTests: XCTestCase {
    func testLocalPeriodicTableElementOpensAfterNativeClick() async throws {
        let (view, window) = try openProject(environmentKey: "WWB_LOCAL_PERIODIC_PROJECT")
        defer { view.prepareForClose(); window.contentView = nil; window.close() }
        try await waitFor(view, expression: "document.querySelectorAll('.element').length === 118")
        let point = try await view.webView.evaluateJavaScript("""
        (() => { const r=document.querySelector('.element .activate').getBoundingClientRect(); return [r.x+r.width/2,r.y+r.height/2]; })()
        """) as? [Double]
        try await click(try XCTUnwrap(point), in: window)
        try await waitFor(view, expression: "document.querySelector('.element .activate').checked")
        try await waitFor(view, expression: "document.querySelector('.element .square').getBoundingClientRect().width > 150")
        let details = try await view.webView.evaluateJavaScript("""
        (() => { const r=document.querySelector('.element .square').getBoundingClientRect(); return {width:r.width,name:document.querySelector('.element .name').textContent}; })()
        """) as? [String:Any]
        XCTAssertEqual(details?["name"] as? String, "Hydrogen")
        print("Local periodic table selected:", details ?? [:])
        try await snapshot(view, name: "periodic")
        try await Task.sleep(for:.milliseconds(600))
        let namePoint = try await view.webView.evaluateJavaScript("(() => {const r=document.querySelector('.element .name').getBoundingClientRect();return [r.x+r.width/2,r.y+r.height/2];})()") as? [Double]
        try await click(try XCTUnwrap(namePoint), in:window)
        let deadline = Date().addingTimeInterval(3)
        while view.pendingExternalURL == nil, Date()<deadline {try await Task.sleep(for:.milliseconds(50))}
        XCTAssertEqual(view.pendingExternalURL?.host,"en.wikipedia.org")
        XCTAssertEqual(view.pendingExternalURL?.lastPathComponent,"Hydrogen")
        var opened: URL?
        view.externalURLOpener = {opened=$0}
        view.openRequestedExternalPage()
        XCTAssertEqual(opened?.host,"en.wikipedia.org")
    }

    func testLocalCubeTurnsASliceAfterNativeClick() async throws {
        let (view, window) = try openProject(environmentKey: "WWB_LOCAL_CUBE_PROJECT")
        defer { view.prepareForClose(); window.contentView = nil; window.close() }
        try await waitFor(view, expression: "!!window.cube && cube.mouseControlsEnabled && cube.twistQueue.future.length === 0 && cube.isTweening() === 0", timeout: 20)
        print("Cube state:", String(describing: try await view.webView.evaluateJavaScript("JSON.stringify({visible:document.visibilityState,time:window.cube?.time,mouse:window.cube?.mouseControlsEnabled,future:window.cube?.twistQueue?.future?.length,history:window.cube?.twistQueue?.history?.length,stickers:document.querySelectorAll('.sticker').length,body:[innerWidth,innerHeight]})")))
        try await snapshot(view, name: "cube-before")
        let original = try await view.webView.evaluateJavaScript("cube.twistQueue.history.length") as? Int
        let point = try await view.webView.evaluateJavaScript("""
        (() => { for(let y=innerHeight*0.3;y<innerHeight*0.7;y+=15) for(let x=innerWidth*0.35;x<innerWidth*0.65;x+=15) {
            const node=document.elementFromPoint(x,y); if(node?.classList.contains('sticker'))return [x,y]; } return null; })()
        """) as? [Double]
        try await click(try XCTUnwrap(point), in: window)
        try await waitFor(view, expression: "cube.twistQueue.history.length > \(try XCTUnwrap(original))", timeout: 5)
        try await waitFor(view, expression: "cube.isTweening() === 0")
        print("Local cube history after face click:", String(describing: try await view.webView.evaluateJavaScript("cube.twistQueue.history.length")))
        try await snapshot(view, name: "cube")
    }

    private func openProject(environmentKey: String) throws -> (RestrictedWebWallpaperView, NSWindow) {
        guard let path = ProcessInfo.processInfo.environment[environmentKey] else { throw XCTSkip("Set \(environmentKey) to an owned local web project") }
        let root = URL(filePath:path).standardizedFileURL.resolvingSymlinksInPath()
        let view = RestrictedWebWallpaperView(url:root.appending(path:"index.html"),readAccessURL:root,frame:CGRect(x:0,y:0,width:1440,height:900))
        let window = DesktopWallpaperWindow(contentRect:CGRect(x:-10000,y:-10000,width:1440,height:900),styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false
        window.setInteractionEnabled(true)
        window.contentView = view
        window.orderFrontRegardless()
        view.webView.configuration.userContentController.addUserScript(WKUserScript(source:"window.__testErrors=[]; addEventListener('error',e=>__testErrors.push(String(e.message)));",injectionTime:.atDocumentStart,forMainFrameOnly:true))
        return (view,window)
    }

    private func waitFor(_ view: RestrictedWebWallpaperView, expression: String, timeout: TimeInterval = 8) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (try? await view.webView.evaluateJavaScript(expression)) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        let errors = try? await view.webView.evaluateJavaScript("window.__testErrors")
        XCTFail("Timed out: \(expression). Page errors: \(String(describing: errors))")
    }

    private func click(_ point: [Double], in window: NSWindow) async throws {
        for type in [NSEvent.EventType.leftMouseDown,.leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with:type,location:CGPoint(x:point[0],y:900-point[1]),modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1))
            window.sendEvent(event)
            try await Task.sleep(for: .milliseconds(80))
        }
    }

    private func snapshot(_ view: RestrictedWebWallpaperView, name: String) async throws {
        guard let directory = ProcessInfo.processInfo.environment["WWB_LOCAL_SNAPSHOTS"] else { return }
        let image = try await view.webView.takeSnapshot(configuration: nil)
        let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:URL(filePath:directory).appending(path:"\(name).png"))
    }
}
