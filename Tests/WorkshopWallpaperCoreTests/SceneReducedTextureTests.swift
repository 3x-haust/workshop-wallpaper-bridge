import XCTest
@testable import WorkshopWallpaperCore

final class SceneReducedTextureTests: XCTestCase {
    func testBlockReductionPreservesColorAndAlphaWithoutFullSheetAllocation() throws {
        // Two 4x4 DXT3 blocks: opaque red, half-transparent green.
        let red: [UInt8] = Array(repeating: 255, count: 8) + [0, 248, 0, 0, 0, 0, 0, 0]
        let green: [UInt8] = Array(repeating: 136, count: 8) + [224, 7, 0, 0, 0, 0, 0, 0]
        let output = try SceneDXTDecoder(format: .dxt3).decodeReduced(Data(red + green), width: 8, height: 4, step: 4)
        XCTAssertEqual(Array(output), [255, 0, 0, 255, 0, 255, 0, 136])
        XCTAssertThrowsError(try SceneDXTDecoder(format: .dxt3).decodeReduced(Data(red), width: 8, height: 4, step: 4))
    }
}
