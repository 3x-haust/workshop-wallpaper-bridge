import Foundation
import XCTest
@testable import WorkshopWallpaperCore

final class SceneTextureDecoderTests: XCTestCase {
    func testDecoderReturnsEmbeddedPngMipmap() throws {
        // Given
        let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAFgwJ/lz8KWwAAAABJRU5ErkJggg=="
        )!
        let data = Fixture.texData(width: 1, height: 1, imageData: png)

        // When
        let texture = try SceneTextureDecoder().decode(data: data)

        // Then
        XCTAssertEqual(texture.width, 1)
        XCTAssertEqual(texture.height, 1)
        XCTAssertEqual(texture.storage, .encodedImage(png))
    }

    func testLZ4DecoderExpandsLiteralOnlyBlock() throws {
        // Given
        let block = Data([0x50]) + Data("hello".utf8)

        // When
        let decoded = try SceneLZ4BlockDecoder().decode(block, expectedSize: 5)

        // Then
        XCTAssertEqual(decoded, Data("hello".utf8))
    }

    func testLZ4DecoderExpandsOverlappingMatch() throws {
        // Given
        let block = Data([0x11, 0x61, 0x01, 0x00])

        // When
        let decoded = try SceneLZ4BlockDecoder().decode(block, expectedSize: 6)

        // Then
        XCTAssertEqual(decoded, Data("aaaaaa".utf8))
    }

    func testLZ4DecoderRejectsOutputAboveConfiguredLimit() throws {
        // Given
        let block = Data([0x50]) + Data("hello".utf8)

        // Then
        XCTAssertThrowsError(try SceneLZ4BlockDecoder().decode(block, expectedSize: 5, maxOutputSize: 4)) { error in
            XCTAssertEqual(error as? SceneTextureError, .invalidLZ4Block)
        }
    }

    func testDecoderRejectsTextureDimensionsAboveSafetyLimit() throws {
        // Given
        let data = Fixture.texData(width: 32_768, height: 32_768, imageData: Data([1, 2, 3]))

        // Then
        XCTAssertThrowsError(try SceneTextureDecoder().decode(data: data)) { error in
            XCTAssertEqual(error as? SceneTextureError, .invalidDimensions)
        }
    }

    func testDecoderChoosesDisplaySizedMipmapForLargeSoftwareTextures() throws {
        // Given
        let fullSizeRed = Data(repeating: 255, count: 4 * 4 * 4)
        let displaySizedGreenPixels = Array(
            repeating: [UInt8(0), UInt8(255), UInt8(0), UInt8(255)],
            count: 2 * 2
        ).flatMap { $0 }
        let data = Self.rawRGBATexture(
            width: 4,
            height: 4,
            mipmaps: [
                (width: 4, height: 4, data: fullSizeRed),
                (width: 2, height: 2, data: Data(displaySizedGreenPixels))
            ]
        )

        // When
        let texture = try SceneTextureDecoder(maximumDisplayDimension: 2).decode(data: data)

        // Then
        XCTAssertEqual(texture.width, 2)
        XCTAssertEqual(texture.height, 2)
        XCTAssertEqual(
            texture.storage,
            SceneTextureStorage.rgba(width: 2, height: 2, data: Data(displaySizedGreenPixels))
        )
    }

    func testDecoderDefaultsToSharperDisplayMipmap() throws {
        // Given
        let largeRedPixels = Array(repeating: UInt8(255), count: 2048 * 2048 * 4)
        let displaySizedGreenPixels = Array(repeating: UInt8(128), count: 1024 * 1024 * 4)
        let smallBluePixels = Array(repeating: UInt8(64), count: 512 * 512 * 4)
        let data = Self.rawRGBATexture(
            width: 2048,
            height: 2048,
            mipmaps: [
                (width: 2048, height: 2048, data: Data(largeRedPixels)),
                (width: 1024, height: 1024, data: Data(displaySizedGreenPixels)),
                (width: 512, height: 512, data: Data(smallBluePixels))
            ]
        )

        // When
        let texture = try SceneTextureDecoder().decode(data: data)

        // Then
        XCTAssertEqual(texture.width, 1024)
        XCTAssertEqual(texture.height, 1024)
    }

    func testDecoderParsesAnimatedSpriteSheetFrames() throws {
        // Given: a 4x2 sheet with a red 2x2 frame on the left and a green 2x2 frame on the right.
        let red: [UInt8] = [255, 0, 0, 255]
        let green: [UInt8] = [0, 255, 0, 255]
        let row: [UInt8] = red + red + green + green
        let sheet = Data(row + row)
        let data = Fixture.animatedTexData(
            textureWidth: 4,
            textureHeight: 2,
            mipmaps: [(width: 4, height: 2, data: sheet)],
            frames: [
                Fixture.TexFrame(frametime: 0.1, x: 0, y: 0, width: 2, height: 2),
                Fixture.TexFrame(frametime: 0.2, x: 2, y: 0, width: 2, height: 2)
            ]
        )

        // When
        let texture = try SceneTextureDecoder().decode(data: data)

        // Then
        XCTAssertEqual(texture.width, 2)
        XCTAssertEqual(texture.height, 2)
        XCTAssertEqual(texture.storage, .rgba(width: 4, height: 2, data: sheet))
        XCTAssertEqual(texture.animationSheets, [texture.storage])
        let animation = try XCTUnwrap(texture.animation)
        XCTAssertEqual(animation.width, 2)
        XCTAssertEqual(animation.height, 2)
        XCTAssertEqual(animation.frames.count, 2)
        XCTAssertEqual(animation.frames[0].duration, 0.1, accuracy: 0.0001)
        XCTAssertEqual(animation.frames[1].duration, 0.2, accuracy: 0.0001)
        XCTAssertEqual(animation.frames[1].x, 2, accuracy: 0.0001)
        XCTAssertEqual(animation.frames[1].width, 2, accuracy: 0.0001)
        XCTAssertEqual(animation.frames[1].height, 2, accuracy: 0.0001)
    }

    func testDecoderParsesIntegerFrameContainer() throws {
        // Given
        let sheet = Data(repeating: 200, count: 4 * 2 * 4)
        let data = Fixture.animatedTexData(
            textureWidth: 4,
            textureHeight: 2,
            mipmaps: [(width: 4, height: 2, data: sheet)],
            frameContainer: "TEXS0001",
            frames: [
                Fixture.TexFrame(frametime: 0.05, x: 0, y: 0, width: 2, height: 2),
                Fixture.TexFrame(frametime: 0.05, x: 2, y: 0, width: 2, height: 2)
            ]
        )

        // When
        let texture = try SceneTextureDecoder().decode(data: data)

        // Then
        let animation = try XCTUnwrap(texture.animation)
        XCTAssertEqual(animation.frames.count, 2)
        XCTAssertEqual(animation.frames[1].x, 2, accuracy: 0.0001)
        XCTAssertEqual(texture.width, 2)
        XCTAssertEqual(texture.height, 2)
    }

    func testDecoderReadsGifSizeFromTEXS0003() throws {
        // Given: a sheet whose frame geometry differs from the declared gif size.
        let sheet = Data(repeating: 90, count: 4 * 2 * 4)
        let data = Fixture.animatedTexData(
            textureWidth: 4,
            textureHeight: 2,
            mipmaps: [(width: 4, height: 2, data: sheet)],
            frameContainer: "TEXS0003",
            gifSize: (width: 1, height: 2),
            frames: [
                Fixture.TexFrame(frametime: 0.1, x: 0, y: 0, width: 2, height: 2)
            ]
        )

        // When
        let texture = try SceneTextureDecoder().decode(data: data)

        // Then
        XCTAssertEqual(texture.width, 1)
        XCTAssertEqual(texture.height, 2)
        XCTAssertEqual(texture.animation?.frames.count, 1)
    }

    func testDecoderScalesFrameGeometryToSelectedMipmap() throws {
        // Given: a 4x4 texture whose 2x2 mipmap is selected for display.
        let fullSheet = Data(repeating: 255, count: 4 * 4 * 4)
        let smallSheet = Data(repeating: 128, count: 2 * 2 * 4)
        let data = Fixture.animatedTexData(
            textureWidth: 4,
            textureHeight: 4,
            mipmaps: [
                (width: 4, height: 4, data: fullSheet),
                (width: 2, height: 2, data: smallSheet)
            ],
            frames: [
                Fixture.TexFrame(frametime: 0.1, x: 2, y: 0, width: 2, height: 4)
            ]
        )

        // When
        let texture = try SceneTextureDecoder(maximumDisplayDimension: 2).decode(data: data)

        // Then
        let animation = try XCTUnwrap(texture.animation)
        XCTAssertEqual(animation.frames[0].x, 1, accuracy: 0.0001)
        XCTAssertEqual(animation.frames[0].width, 1, accuracy: 0.0001)
        XCTAssertEqual(animation.frames[0].height, 2, accuracy: 0.0001)
        XCTAssertEqual(texture.storage, .rgba(width: 2, height: 2, data: smallSheet))
    }

    func testDecoderFallsBackToStaticSheetWhenFrameContainerIsMissing() throws {
        // Given: the gif flag is set but no TEXS container follows the image data.
        let sheet = Data(repeating: 40, count: 4 * 2 * 4)
        let data = Fixture.animatedTexData(
            textureWidth: 4,
            textureHeight: 2,
            mipmaps: [(width: 4, height: 2, data: sheet)],
            frameContainer: nil
        )

        // When
        let texture = try SceneTextureDecoder().decode(data: data)

        // Then
        XCTAssertNil(texture.animation)
        XCTAssertEqual(texture.width, 4)
        XCTAssertEqual(texture.height, 2)
    }

    func testDecoderRejectsVideoTextureFlag() throws {
        // Given
        let sheet = Data(repeating: 10, count: 4 * 2 * 4)
        let data = Fixture.animatedTexData(
            textureWidth: 4,
            textureHeight: 2,
            flags: 0x20,
            mipmaps: [(width: 4, height: 2, data: sheet)],
            frameContainer: nil
        )

        // Then
        XCTAssertThrowsError(try SceneTextureDecoder().decode(data: data)) { error in
            XCTAssertEqual(error as? SceneTextureError, .unsupportedTextureFlags(0x20))
        }
    }

    func testDecoderRejectsEmbeddedMP4VideoContainer() throws {
        // Given
        let sheet = Data(repeating: 10, count: 4 * 2 * 4)
        let data = Fixture.animatedTexData(
            textureWidth: 4,
            textureHeight: 2,
            container: "TEXB0004",
            isVideoMP4: true,
            mipmaps: [(width: 4, height: 2, data: sheet)],
            frameContainer: nil
        )

        // Then
        XCTAssertThrowsError(try SceneTextureDecoder().decode(data: data)) { error in
            XCTAssertEqual(error as? SceneTextureError, .unsupportedVideoTexture)
        }
    }

    func testDecoderReadsNonVideoTEXB0004Container() throws {
        // Given
        let sheet = Data(repeating: 30, count: 2 * 2 * 4)
        let data = Fixture.animatedTexData(
            textureWidth: 2,
            textureHeight: 2,
            flags: 0,
            container: "TEXB0004",
            mipmaps: [(width: 2, height: 2, data: sheet)],
            frameContainer: nil
        )

        // When
        let texture = try SceneTextureDecoder().decode(data: data)

        // Then
        XCTAssertEqual(texture.storage, .rgba(width: 2, height: 2, data: sheet))
    }

    private static func rawRGBATexture(
        width: Int,
        height: Int,
        mipmaps: [(width: Int, height: Int, data: Data)]
    ) -> Data {
        var data = Data()
        data.appendNullTerminatedString("TEXV0005")
        data.appendNullTerminatedString("TEXI0001")
        data.appendInt32(0)
        data.appendInt32(0)
        data.appendInt32(width)
        data.appendInt32(height)
        data.appendInt32(width)
        data.appendInt32(height)
        data.appendUInt32(0)
        data.appendNullTerminatedString("TEXB0003")
        data.appendInt32(1)
        data.appendInt32(0)
        data.appendInt32(mipmaps.count)
        for mipmap in mipmaps {
            data.appendInt32(mipmap.width)
            data.appendInt32(mipmap.height)
            data.appendInt32(0)
            data.appendInt32(0)
            data.appendInt32(mipmap.data.count)
            data.append(mipmap.data)
        }
        return data
    }
}

private extension Data {
    mutating func appendInt32(_ value: Int) {
        var raw = Int32(value).littleEndian
        Swift.withUnsafeBytes(of: &raw) { append(contentsOf: $0) }
    }

    mutating func appendUInt32(_ value: UInt32) {
        var raw = value.littleEndian
        Swift.withUnsafeBytes(of: &raw) { append(contentsOf: $0) }
    }

    mutating func appendNullTerminatedString(_ string: String) {
        append(Data(string.utf8))
        append(0)
    }
}
