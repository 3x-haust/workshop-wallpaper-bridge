import XCTest
@testable import WorkshopWallpaperBridgeApp

final class WallpaperSpectrumAnalyzerTests: XCTestCase {
    func testSilenceAndIndependentStereoToneFrequencies() throws {
        let analyzer = WallpaperSpectrumAnalyzer()
        let count = WallpaperSpectrumAnalyzer.frameCount
        let silence = Array(repeating: Float(0), count: count)
        let zero = try XCTUnwrap(analyzer.append(left: silence, right: silence, sampleRate: 48_000))
        XCTAssertEqual(zero.left, Array(repeating: 0, count: 64))
        let tone = (0..<count).map { Float(sin(2 * .pi * 1000 * Double($0) / 48_000)) }
        let result = try XCTUnwrap(analyzer.append(left: tone, right: silence, sampleRate: 48_000))
        let peak = try XCTUnwrap(result.left.indices.max(by: { result.left[$0] < result.left[$1] }))
        // A 1 kHz input lies at log(1000/20)/log(20000/20) of the spectrum.
        XCTAssertTrue((35...37).contains(peak))
        XCTAssertGreaterThan(result.left[peak], 0.5)
        XCTAssertEqual(result.right, Array(repeating: 0, count: 64))
    }

    func testAccumulatesShortBuffersAndRejectsNonfiniteSamples() throws {
        let analyzer = WallpaperSpectrumAnalyzer()
        let samples = Array(repeating: Float.nan, count: WallpaperSpectrumAnalyzer.frameCount / 2)
        XCTAssertNil(analyzer.append(left: samples, right: samples, sampleRate: 48_000))
        let result = try XCTUnwrap(analyzer.append(left: samples, right: samples, sampleRate: 48_000))
        XCTAssertTrue(result.left.allSatisfy { $0 == 0 })
    }
}
