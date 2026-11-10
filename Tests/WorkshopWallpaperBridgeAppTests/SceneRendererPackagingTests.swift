import Foundation
import XCTest

final class SceneRendererPackagingTests: XCTestCase {
    func testMissingRendererIsBuiltAndBundledWithLibrariesAndNotices() throws {
        let root = try fixture(builder: """
        mkdir -p "$ROOT/ExternalRenderers/Licenses"
        printf '#!/bin/sh\\nexit 0\\n' > "$ROOT/ExternalRenderers/wwb-scene-renderer"
        chmod +x "$ROOT/ExternalRenderers/wwb-scene-renderer"
        printf 'library' > "$ROOT/ExternalRenderers/renderer.dylib"
        printf 'license' > "$ROOT/ExternalRenderers/Licenses/LICENSE"
        """)
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try bundle(in: root)

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: root.appending(path: "Resources/Renderers/wwb-scene-renderer").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "Resources/Renderers/renderer.dylib").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appending(path: "Resources/Renderer Notices/Licenses/LICENSE").path))
        let notice = try String(contentsOf: root.appending(path: "Resources/Renderer Notices/notice.txt"), encoding: .utf8)
        XCTAssertFalse(notice.contains("not bundled"))
    }

    func testFailedOrIncompleteRendererBuildStopsPackaging() throws {
        for builder in ["exit 17", "exit 0"] {
            let root = try fixture(builder: builder)
            defer { try? FileManager.default.removeItem(at: root) }

            let result = try bundle(in: root)

            XCTAssertNotEqual(result.status, 0, "Packaging must not succeed without a renderer: \(result.output)")
        }
    }

    func testExplicitRendererDoesNotBuildAnotherCopy() throws {
        let root = try fixture(builder: "exit 17")
        defer { try? FileManager.default.removeItem(at: root) }
        let renderer = root.appending(path: "custom-renderer")
        try "#!/bin/sh\nexit 0\n".write(to: renderer, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: renderer.path)

        let result = try bundle(in: root, renderer: renderer.path)

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: root.appending(path: "Resources/Renderers/wwb-scene-renderer").path))
    }

    private func fixture(builder: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "scene-package-\(UUID())")
        try FileManager.default.createDirectory(at: root.appending(path: "Scripts"), withIntermediateDirectories: true)
        try "#!/bin/bash\nset -eu\n\(builder)\n".write(to: root.appending(path: "Scripts/build-scene-renderer.sh"), atomically: true, encoding: .utf8)
        return root
    }

    private func bundle(in root: URL, renderer: String = "") throws -> (status: Int32, output: String) {
        let repository = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: repository.appending(path: "Scripts/package-app.sh"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "bundle_scene_renderer_if_available() {"))
        let end = try XCTUnwrap(source.range(of: "\nverify_gatekeeper_accepts_quarantined_app_from_dmg()", range: start.lowerBound..<source.endIndex))
        let function = String(source[start.lowerBound..<end.lowerBound])
        let process = Process()
        process.executableURL = URL(filePath: "/bin/bash")
        process.arguments = ["-c", "set -euo pipefail\n\(function)\nbundle_scene_renderer_if_available"]
        var environment = ProcessInfo.processInfo.environment
        environment.merge([
            "ROOT": root.path,
            "SCENE_RENDERER_BINARY": renderer,
            "SCENE_RENDERER_CONVENTIONAL_PATH": root.appending(path: "ExternalRenderers/wwb-scene-renderer").path,
            "SCENE_RENDERER_BUNDLED_PATH": "",
            "RENDERERS_DIR": root.appending(path: "Resources/Renderers").path,
            "RENDERER_NOTICE_DIR": root.appending(path: "Resources/Renderer Notices").path,
            "RENDERER_NOTICE_PATH": root.appending(path: "Resources/Renderer Notices/notice.txt").path,
            "SCENE_RENDERER_SOURCE_URL": "https://example.invalid/renderer",
            "SCENE_RENDERER_SOURCE_REF": "test-ref"
        ], uniquingKeysWith: { _, value in value })
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }
}
