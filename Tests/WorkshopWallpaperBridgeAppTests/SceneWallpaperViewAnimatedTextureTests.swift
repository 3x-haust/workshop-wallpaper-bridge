import AppKit
import WorkshopWallpaperCore
import XCTest
@testable import WorkshopWallpaperBridgeApp

final class SceneWallpaperViewAnimatedTextureTests: XCTestCase {
    func testAnimationFrameContentsCutsAxisAlignedFrames() throws {
        // Given: a 4x2 sheet with a red 2x2 frame on the left and a green 2x2 frame on the right.
        let texture = Self.texture(
            sheetWidth: 4,
            sheetHeight: 2,
            pixels: [
                [.red, .red, .green, .green],
                [.red, .red, .green, .green]
            ],
            frames: [
                SceneTextureFrame(imageIndex: 0, duration: 0.1, x: 0, y: 0, width: 2, widthY: 0, heightX: 0, height: 2),
                SceneTextureFrame(imageIndex: 0, duration: 0.3, x: 2, y: 0, width: 2, widthY: 0, heightX: 0, height: 2)
            ]
        )

        // When
        let contents = try XCTUnwrap(SceneWallpaperView.animationFrameContents(for: texture))

        // Then
        XCTAssertEqual(contents.images.count, 2)
        XCTAssertEqual(contents.images[0].width, 2)
        XCTAssertEqual(contents.images[0].height, 2)
        XCTAssertEqual(Self.pixel(of: contents.images[0], x: 0, y: 0), .red)
        XCTAssertEqual(Self.pixel(of: contents.images[1], x: 0, y: 0), .green)
        XCTAssertEqual(contents.duration, 0.4, accuracy: 0.0001)
        XCTAssertEqual(contents.keyTimes.count, 3)
        XCTAssertEqual(contents.keyTimes[0].doubleValue, 0, accuracy: 0.0001)
        XCTAssertEqual(contents.keyTimes[1].doubleValue, 0.25, accuracy: 0.0001)
        XCTAssertEqual(contents.keyTimes[2].doubleValue, 1, accuracy: 0.0001)
    }

    func testAnimationFrameContentsReconstructsRotatedFrame() throws {
        // Given: a 2x1 displayed frame stored as a vertical 1x2 strip,
        // so the destination x axis advances down the sheet.
        let texture = Self.texture(
            sheetWidth: 1,
            sheetHeight: 2,
            pixels: [
                [.red],
                [.green]
            ],
            frames: [
                SceneTextureFrame(imageIndex: 0, duration: 0.1, x: 0, y: 0, width: 0, widthY: 2, heightX: 1, height: 0)
            ]
        )

        // When
        let contents = try XCTUnwrap(SceneWallpaperView.animationFrameContents(for: texture))

        // Then
        XCTAssertEqual(contents.images.count, 1)
        XCTAssertEqual(contents.images[0].width, 2)
        XCTAssertEqual(contents.images[0].height, 1)
        XCTAssertEqual(Self.pixel(of: contents.images[0], x: 0, y: 0), .red)
        XCTAssertEqual(Self.pixel(of: contents.images[0], x: 1, y: 0), .green)
    }

    func testAnimationFrameContentsRejectsOversizedFrames() {
        let texture = Self.texture(
            sheetWidth: 2,
            sheetHeight: 2,
            pixels: [
                [.red, .red],
                [.red, .red]
            ],
            frames: [
                SceneTextureFrame(
                    imageIndex: 0,
                    duration: 0.1,
                    x: 0,
                    y: 0,
                    width: 100_000,
                    widthY: 0,
                    heightX: 0,
                    height: 100_000
                )
            ]
        )

        XCTAssertNil(SceneWallpaperView.animationFrameContents(for: texture))
    }

    func testAnimationFrameContentsIsNilForStaticTextures() {
        let texture = Self.texture(
            sheetWidth: 1,
            sheetHeight: 1,
            pixels: [[.red]],
            frames: []
        )

        XCTAssertNil(SceneWallpaperView.animationFrameContents(for: texture))
    }

    func testTextureFrameAnimationUsesDiscreteInfiniteContentsKeyframes() throws {
        let texture = Self.texture(
            sheetWidth: 4,
            sheetHeight: 2,
            pixels: [
                [.red, .red, .green, .green],
                [.red, .red, .green, .green]
            ],
            frames: [
                SceneTextureFrame(imageIndex: 0, duration: 0.1, x: 0, y: 0, width: 2, widthY: 0, heightX: 0, height: 2),
                SceneTextureFrame(imageIndex: 0, duration: 0.1, x: 2, y: 0, width: 2, widthY: 0, heightX: 0, height: 2)
            ]
        )
        let contents = try XCTUnwrap(SceneWallpaperView.animationFrameContents(for: texture))

        let animation = SceneWallpaperView.textureFrameAnimation(for: contents)

        XCTAssertEqual(animation.keyPath, "contents")
        XCTAssertEqual(animation.calculationMode, .discrete)
        XCTAssertEqual(animation.repeatCount, .infinity)
        XCTAssertEqual(animation.duration, contents.duration, accuracy: 0.0001)
        XCTAssertEqual(animation.values?.count, 2)
        XCTAssertEqual(animation.keyTimes?.count, 3)
    }

    func testFrameSheetTransformRejectsDegenerateAxes() {
        let degenerate = SceneTextureFrame(
            imageIndex: 0,
            duration: 0.1,
            x: 0,
            y: 0,
            width: 0,
            widthY: 0,
            heightX: 0,
            height: 2
        )

        XCTAssertNil(SceneWallpaperView.frameSheetTransform(for: degenerate))
    }

    // MARK: - Helpers

    private enum Pixel: Equatable {
        case red
        case green
        case other(UInt8, UInt8, UInt8, UInt8)

        var rgba: [UInt8] {
            switch self {
            case .red:
                return [255, 0, 0, 255]
            case .green:
                return [0, 255, 0, 255]
            case .other(let red, let green, let blue, let alpha):
                return [red, green, blue, alpha]
            }
        }

        static func from(rgba: [UInt8]) -> Pixel {
            if rgba == Pixel.red.rgba {
                return .red
            }
            if rgba == Pixel.green.rgba {
                return .green
            }
            return .other(rgba[0], rgba[1], rgba[2], rgba[3])
        }
    }

    private static func texture(
        sheetWidth: Int,
        sheetHeight: Int,
        pixels: [[Pixel]],
        frames: [SceneTextureFrame]
    ) -> SceneTexture {
        let data = Data(pixels.flatMap { row in row.flatMap(\.rgba) })
        let storage = SceneTextureStorage.rgba(width: sheetWidth, height: sheetHeight, data: data)
        guard !frames.isEmpty else {
            return SceneTexture(width: sheetWidth, height: sheetHeight, storage: storage)
        }
        let first = frames[0]
        return SceneTexture(
            width: Int(max(abs(first.width), abs(first.widthY)).rounded()),
            height: Int(max(abs(first.heightX), abs(first.height)).rounded()),
            storage: storage,
            animation: SceneTextureAnimation(
                width: max(abs(first.width), abs(first.widthY)),
                height: max(abs(first.heightX), abs(first.height)),
                frames: frames
            ),
            animationSheets: [storage]
        )
    }

    private static func pixel(of image: CGImage, x: Int, y: Int) -> Pixel {
        let width = image.width
        let height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        buffer.withUnsafeMutableBytes { pointer in
            guard let context = CGContext(
                data: pointer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return
            }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let index = (y * width + x) * 4
        return Pixel.from(rgba: Array(buffer[index..<(index + 4)]))
    }
}
