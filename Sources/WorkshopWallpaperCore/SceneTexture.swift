import Foundation

public struct SceneTexture: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let storage: SceneTextureStorage
    public let animation: SceneTextureAnimation?
    public let animationSheets: [SceneTextureStorage]

    public init(
        width: Int,
        height: Int,
        storage: SceneTextureStorage,
        animation: SceneTextureAnimation? = nil,
        animationSheets: [SceneTextureStorage] = []
    ) {
        self.width = width
        self.height = height
        self.storage = storage
        self.animation = animation
        self.animationSheets = animationSheets
    }
}

/// One sprite-sheet frame of an animated `.tex` texture.
///
/// Geometry follows the RePKG/RePKG.Neo TEXS layout: `(x, y)` is the frame
/// anchor and `(width, widthY)` / `(heightX, height)` are the sheet-space
/// direction vectors for the frame's horizontal and vertical axes, so rotated
/// or flipped packing is representable. All values are in pixels of the
/// decoded sheet referenced by `imageIndex`.
public struct SceneTextureFrame: Equatable, Sendable {
    public let imageIndex: Int
    public let duration: Double
    public let x: Double
    public let y: Double
    public let width: Double
    public let widthY: Double
    public let heightX: Double
    public let height: Double

    public init(
        imageIndex: Int,
        duration: Double,
        x: Double,
        y: Double,
        width: Double,
        widthY: Double,
        heightX: Double,
        height: Double
    ) {
        self.imageIndex = imageIndex
        self.duration = duration
        self.x = x
        self.y = y
        self.width = width
        self.widthY = widthY
        self.heightX = heightX
        self.height = height
    }
}

public struct SceneTextureAnimation: Equatable, Sendable {
    public let width: Double
    public let height: Double
    public let frames: [SceneTextureFrame]

    public init(width: Double, height: Double, frames: [SceneTextureFrame]) {
        self.width = width
        self.height = height
        self.frames = frames
    }
}

public enum SceneTextureStorage: Equatable, Sendable {
    case encodedImage(Data)
    case rgba(width: Int, height: Int, data: Data)
}

public struct SceneTextureDecoder: Sendable {
    private static let maximumTextureDimension = 16_384
    private static let maximumCompressedPayloadBytes = 64 * 1024 * 1024

    private let maximumSoftwareDecodedPixels: Int
    private let maximumDisplayDimension: Int

    public init(maximumSoftwareDecodedPixels: Int = 18_000_000, maximumDisplayDimension: Int = 1024) {
        self.maximumSoftwareDecodedPixels = maximumSoftwareDecodedPixels
        self.maximumDisplayDimension = maximumDisplayDimension
    }

    public func decode(data: Data) throws -> SceneTexture {
        var reader = SceneTextureBinaryReader(data: data)
        let version = try reader.readCString(maxLength: 32)
        guard version.hasPrefix("TEXV") else {
            throw SceneTextureError.unsupportedMagic(version)
        }
        let info = try reader.readCString(maxLength: 32)
        guard info.hasPrefix("TEXI") else {
            throw SceneTextureError.unsupportedMagic(info)
        }
        let format = try reader.readInt()
        let flags = try reader.readInt()
        guard flags & 0x20 == 0 else {
            throw SceneTextureError.unsupportedTextureFlags(flags)
        }
        let isAnimated = flags & 0x04 != 0
        let textureWidth = try reader.readInt()
        let textureHeight = try reader.readInt()
        let imageWidth = try reader.readInt()
        let imageHeight = try reader.readInt()
        _ = try reader.readUInt32()
        try validateDimensions(
            textureWidth: textureWidth,
            textureHeight: textureHeight,
            imageWidth: imageWidth,
            imageHeight: imageHeight
        )
        let container = try reader.readCString(maxLength: 32)
        let imageCount = try Self.readImageContainerHeader(container: container, reader: &reader)
        let mipmapReader = SceneTextureMipmapReader(container: container)
        let sheetCount = isAnimated ? imageCount : 1
        var sheets: [DecodedSheet] = []
        sheets.reserveCapacity(sheetCount)
        for _ in 0..<sheetCount {
            let mipmap = try mipmapReader.readBestMipmap(from: &reader, maximumDimension: maximumDisplayDimension)
            sheets.append(try decodeSheet(
                mipmap,
                format: format,
                textureWidth: textureWidth,
                textureHeight: textureHeight,
                imageWidth: imageWidth,
                imageHeight: imageHeight
            ))
        }
        guard let primary = sheets.first else {
            throw SceneTextureError.truncatedTexture
        }
        if isAnimated, let animation = Self.readAnimation(from: &reader, sheets: sheets) {
            return SceneTexture(
                width: max(1, Int(animation.width.rounded())),
                height: max(1, Int(animation.height.rounded())),
                storage: primary.storage,
                animation: animation,
                animationSheets: sheets.map(\.storage)
            )
        }
        return SceneTexture(width: primary.width, height: primary.height, storage: primary.storage)
    }

    private struct DecodedSheet {
        let storage: SceneTextureStorage
        let width: Int
        let height: Int
        let frameScaleX: Double
        let frameScaleY: Double
    }

    private static func readImageContainerHeader(
        container: String,
        reader: inout SceneTextureBinaryReader
    ) throws -> Int {
        let imageCount = try reader.readInt()
        guard imageCount > 0, imageCount <= 64 else {
            throw SceneTextureError.invalidCount(imageCount)
        }
        switch container {
        case "TEXB0001", "TEXB0002":
            break
        case "TEXB0003":
            _ = try reader.readInt()
        case "TEXB0004":
            _ = try reader.readInt()
            let isVideoMP4 = try reader.readInt()
            guard isVideoMP4 != 1 else {
                throw SceneTextureError.unsupportedVideoTexture
            }
        default:
            throw SceneTextureError.unsupportedContainer(container)
        }
        return imageCount
    }

    private func decodeSheet(
        _ mipmap: SceneTextureMipmap,
        format: Int,
        textureWidth: Int,
        textureHeight: Int,
        imageWidth: Int,
        imageHeight: Int
    ) throws -> DecodedSheet {
        let pixelCount = try Self.checkedProduct(mipmap.width, mipmap.height)
        if mipmap.compressed, pixelCount > maximumSoftwareDecodedPixels {
            throw SceneTextureError.textureTooLargeForSoftwareDecode(mipmap.width, mipmap.height)
        }
        let payload = try decodePayload(mipmap)
        let frameScaleX = Double(mipmap.width) / Double(textureWidth)
        let frameScaleY = Double(mipmap.height) / Double(textureHeight)
        if Self.isEncodedImage(payload) {
            return DecodedSheet(
                storage: .encodedImage(payload),
                width: scaledWidth(imageWidth, textureWidth: textureWidth, mipmapWidth: mipmap.width),
                height: scaledHeight(imageHeight, textureHeight: textureHeight, mipmapHeight: mipmap.height),
                frameScaleX: frameScaleX,
                frameScaleY: frameScaleY
            )
        }
        guard pixelCount <= maximumSoftwareDecodedPixels else {
            throw SceneTextureError.textureTooLargeForSoftwareDecode(mipmap.width, mipmap.height)
        }
        let targetWidth = scaledWidth(imageWidth, textureWidth: textureWidth, mipmapWidth: mipmap.width)
        let targetHeight = scaledHeight(imageHeight, textureHeight: textureHeight, mipmapHeight: mipmap.height)
        let rgba = try decodeRGBA(
            payload,
            format: format,
            textureWidth: mipmap.width,
            textureHeight: mipmap.height,
            imageWidth: targetWidth,
            imageHeight: targetHeight
        )
        return DecodedSheet(
            storage: .rgba(width: targetWidth, height: targetHeight, data: rgba),
            width: targetWidth,
            height: targetHeight,
            frameScaleX: frameScaleX,
            frameScaleY: frameScaleY
        )
    }

    private static let maximumAnimationFrameCount = 4_096
    private static let defaultAnimationFrameDuration = 1.0 / 30.0

    /// Reads the trailing TEXS frame-info container of an animated texture.
    /// Returns nil instead of throwing so a malformed or truncated frame
    /// container degrades to static sheet playback rather than rejecting the
    /// whole texture.
    private static func readAnimation(
        from reader: inout SceneTextureBinaryReader,
        sheets: [DecodedSheet]
    ) -> SceneTextureAnimation? {
        guard let container = try? reader.readCString(maxLength: 32),
              container == "TEXS0001" || container == "TEXS0002" || container == "TEXS0003" else {
            return nil
        }
        let usesIntegerGeometry = container == "TEXS0001"
        guard let frameCount = try? reader.readInt(),
              frameCount > 0,
              frameCount <= maximumAnimationFrameCount else {
            return nil
        }
        var gifWidth = 0.0
        var gifHeight = 0.0
        if container == "TEXS0003" {
            guard let width = try? reader.readInt(), let height = try? reader.readInt() else {
                return nil
            }
            gifWidth = Double(width)
            gifHeight = Double(height)
        }
        var frames: [SceneTextureFrame] = []
        frames.reserveCapacity(frameCount)
        for _ in 0..<frameCount {
            guard let imageId = try? reader.readInt(),
                  let frametime = try? reader.readFloat(),
                  let geometry = try? readFrameGeometry(from: &reader, asIntegers: usesIntegerGeometry) else {
                return nil
            }
            if gifWidth <= 0 || gifHeight <= 0 {
                gifWidth = abs(geometry.width != 0 ? geometry.width : geometry.heightX)
                gifHeight = abs(geometry.height != 0 ? geometry.height : geometry.widthY)
            }
            guard imageId >= 0, imageId < sheets.count else {
                continue
            }
            let sheet = sheets[imageId]
            let duration = frametime.isFinite && frametime > 0 ? Double(frametime) : defaultAnimationFrameDuration
            frames.append(SceneTextureFrame(
                imageIndex: imageId,
                duration: duration,
                x: geometry.x * sheet.frameScaleX,
                y: geometry.y * sheet.frameScaleY,
                width: geometry.width * sheet.frameScaleX,
                widthY: geometry.widthY * sheet.frameScaleY,
                heightX: geometry.heightX * sheet.frameScaleX,
                height: geometry.height * sheet.frameScaleY
            ))
        }
        guard !frames.isEmpty, gifWidth > 0, gifHeight > 0 else {
            return nil
        }
        return SceneTextureAnimation(width: gifWidth, height: gifHeight, frames: frames)
    }

    private struct FrameGeometry {
        let x: Double
        let y: Double
        let width: Double
        let widthY: Double
        let heightX: Double
        let height: Double
    }

    private static func readFrameGeometry(
        from reader: inout SceneTextureBinaryReader,
        asIntegers: Bool
    ) throws -> FrameGeometry {
        func value() throws -> Double {
            if asIntegers {
                return Double(try reader.readInt())
            }
            let float = try reader.readFloat()
            guard float.isFinite else {
                throw SceneTextureError.truncatedTexture
            }
            return Double(float)
        }
        return FrameGeometry(
            x: try value(),
            y: try value(),
            width: try value(),
            widthY: try value(),
            heightX: try value(),
            height: try value()
        )
    }

    private func scaledWidth(_ imageWidth: Int, textureWidth: Int, mipmapWidth: Int) -> Int {
        max(1, min(mipmapWidth, Int((Double(imageWidth) / Double(textureWidth) * Double(mipmapWidth)).rounded())))
    }

    private func scaledHeight(_ imageHeight: Int, textureHeight: Int, mipmapHeight: Int) -> Int {
        max(1, min(mipmapHeight, Int((Double(imageHeight) / Double(textureHeight) * Double(mipmapHeight)).rounded())))
    }

    private func validateDimensions(
        textureWidth: Int,
        textureHeight: Int,
        imageWidth: Int,
        imageHeight: Int
    ) throws {
        guard textureWidth > 0,
              textureHeight > 0,
              imageWidth > 0,
              imageHeight > 0,
              textureWidth <= Self.maximumTextureDimension,
              textureHeight <= Self.maximumTextureDimension,
              imageWidth <= textureWidth,
              imageHeight <= textureHeight else {
            throw SceneTextureError.invalidDimensions
        }
        _ = try Self.checkedRGBAByteCount(width: textureWidth, height: textureHeight)
        _ = try Self.checkedRGBAByteCount(width: imageWidth, height: imageHeight)
    }

    private func decodePayload(_ mipmap: SceneTextureMipmap) throws -> Data {
        guard mipmap.compressed else {
            return mipmap.data
        }
        guard let decompressedSize = mipmap.decompressedSize else {
            throw SceneTextureError.missingDecompressedSize
        }
        return try SceneLZ4BlockDecoder().decode(
            mipmap.data,
            expectedSize: decompressedSize,
            maxOutputSize: Self.maximumCompressedPayloadBytes
        )
    }

    private func decodeRGBA(
        _ payload: Data,
        format: Int,
        textureWidth: Int,
        textureHeight: Int,
        imageWidth: Int,
        imageHeight: Int
    ) throws -> Data {
        switch format {
        case 0:
            return try SceneTextureDecoder.cropRGBA(
                payload,
                sourceWidth: textureWidth,
                sourceHeight: textureHeight,
                targetWidth: imageWidth,
                targetHeight: imageHeight
            )
        case 4:
            let rgba = try SceneDXTDecoder(format: .dxt5).decode(
                payload,
                width: textureWidth,
                height: textureHeight
            )
            return try SceneTextureDecoder.cropRGBA(
                rgba,
                sourceWidth: textureWidth,
                sourceHeight: textureHeight,
                targetWidth: imageWidth,
                targetHeight: imageHeight
            )
        case 6:
            let rgba = try SceneDXTDecoder(format: .dxt3).decode(
                payload,
                width: textureWidth,
                height: textureHeight
            )
            return try SceneTextureDecoder.cropRGBA(
                rgba,
                sourceWidth: textureWidth,
                sourceHeight: textureHeight,
                targetWidth: imageWidth,
                targetHeight: imageHeight
            )
        case 7:
            let rgba = try SceneDXTDecoder(format: .dxt1).decode(
                payload,
                width: textureWidth,
                height: textureHeight
            )
            return try SceneTextureDecoder.cropRGBA(
                rgba,
                sourceWidth: textureWidth,
                sourceHeight: textureHeight,
                targetWidth: imageWidth,
                targetHeight: imageHeight
            )
        case 8:
            return try expandRG88(
                payload,
                sourceWidth: textureWidth,
                sourceHeight: textureHeight,
                targetWidth: imageWidth,
                targetHeight: imageHeight
            )
        case 9:
            return try expandR8(
                payload,
                sourceWidth: textureWidth,
                sourceHeight: textureHeight,
                targetWidth: imageWidth,
                targetHeight: imageHeight
            )
        default:
            throw SceneTextureError.unsupportedFormat(format)
        }
    }

    private func expandRG88(
        _ payload: Data,
        sourceWidth: Int,
        sourceHeight: Int,
        targetWidth: Int,
        targetHeight: Int
    ) throws -> Data {
        let pixelCount = try Self.checkedProduct(sourceWidth, sourceHeight)
        let expected = try Self.checkedProduct(pixelCount, 2)
        guard payload.count >= expected else {
            throw SceneTextureError.truncatedTexture
        }
        var rgba = Data()
        rgba.reserveCapacity(try Self.checkedProduct(pixelCount, 4))
        for index in 0..<pixelCount {
            let base = index * 2
            let red = payload[base]
            let green = payload[base + 1]
            rgba.append(contentsOf: [red, green, 0, 255])
        }
        return try Self.cropRGBA(
            rgba,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            targetWidth: targetWidth,
            targetHeight: targetHeight
        )
    }

    private func expandR8(
        _ payload: Data,
        sourceWidth: Int,
        sourceHeight: Int,
        targetWidth: Int,
        targetHeight: Int
    ) throws -> Data {
        let expected = try Self.checkedProduct(sourceWidth, sourceHeight)
        guard payload.count >= expected else {
            throw SceneTextureError.truncatedTexture
        }
        var rgba = Data()
        rgba.reserveCapacity(try Self.checkedProduct(expected, 4))
        for value in payload.prefix(expected) {
            rgba.append(contentsOf: [value, value, value, 255])
        }
        return try Self.cropRGBA(
            rgba,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            targetWidth: targetWidth,
            targetHeight: targetHeight
        )
    }

    private static func cropRGBA(
        _ data: Data,
        sourceWidth: Int,
        sourceHeight: Int,
        targetWidth: Int,
        targetHeight: Int
    ) throws -> Data {
        let expected = try checkedRGBAByteCount(width: sourceWidth, height: sourceHeight)
        guard sourceWidth > 0, sourceHeight > 0,
              targetWidth > 0, targetHeight > 0,
              targetWidth <= sourceWidth, targetHeight <= sourceHeight,
              data.count >= expected else {
            throw SceneTextureError.truncatedTexture
        }
        guard sourceWidth != targetWidth || sourceHeight != targetHeight else {
            return data.prefix(expected)
        }
        var cropped = Data()
        cropped.reserveCapacity(try checkedRGBAByteCount(width: targetWidth, height: targetHeight))
        let targetRowBytes = try checkedProduct(targetWidth, 4)
        for row in 0..<targetHeight {
            let start = try checkedProduct(try checkedProduct(row, sourceWidth), 4)
            let end = start + targetRowBytes
            cropped.append(data[start..<end])
        }
        return cropped
    }

    private static func checkedRGBAByteCount(width: Int, height: Int) throws -> Int {
        try checkedProduct(try checkedProduct(width, height), 4)
    }

    private static func checkedProduct(_ lhs: Int, _ rhs: Int) throws -> Int {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        guard !result.overflow else {
            throw SceneTextureError.invalidDimensions
        }
        return result.partialValue
    }

    private static func isEncodedImage(_ data: Data) -> Bool {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return true
        }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) {
            return true
        }
        if data.starts(with: Data("GIF87a".utf8)) || data.starts(with: Data("GIF89a".utf8)) {
            return true
        }
        if data.starts(with: Data("RIFF".utf8)) && data.count >= 12 {
            return data[8..<12] == Data("WEBP".utf8)
        }
        return false
    }
}

public enum SceneTextureError: Error, Equatable, LocalizedError {
    case unsupportedMagic(String)
    case unsupportedContainer(String)
    case unsupportedFormat(Int)
    case unsupportedTextureFlags(Int)
    case unsupportedVideoTexture
    case textureTooLargeForSoftwareDecode(Int, Int)
    case invalidDimensions
    case invalidCount(Int)
    case invalidString
    case invalidLZ4Block
    case invalidMatchOffset
    case missingDecompressedSize
    case truncatedTexture

    public var errorDescription: String? {
        switch self {
        case .unsupportedMagic(let magic):
            return "Unsupported scene texture magic: \(magic)."
        case .unsupportedContainer(let container):
            return "Unsupported scene texture container: \(container)."
        case .unsupportedFormat(let format):
            return "Unsupported scene texture format: \(format)."
        case .unsupportedTextureFlags(let flags):
            return "Unsupported video scene texture flags: \(flags)."
        case .unsupportedVideoTexture:
            return "Embedded MP4 video scene textures are not supported."
        case .textureTooLargeForSoftwareDecode(let width, let height):
            return "Scene texture \(width)x\(height) is too large for the current software decoder."
        case .invalidDimensions:
            return "The scene texture has invalid dimensions."
        case .invalidCount(let count):
            return "The scene texture has an invalid count: \(count)."
        case .invalidString:
            return "The scene texture contains an invalid string."
        case .invalidLZ4Block:
            return "The scene texture contains an invalid LZ4 block."
        case .invalidMatchOffset:
            return "The scene texture contains an invalid LZ4 match offset."
        case .missingDecompressedSize:
            return "The scene texture is missing its decompressed size."
        case .truncatedTexture:
            return "The scene texture is truncated."
        }
    }
}

private struct SceneTextureMipmap {
    let width: Int
    let height: Int
    let compressed: Bool
    let decompressedSize: Int?
    let data: Data
}

private struct SceneTextureMipmapReader {
    let container: String

    func readBestMipmap(from reader: inout SceneTextureBinaryReader, maximumDimension: Int) throws -> SceneTextureMipmap {
        let mipmapCount = try reader.readInt()
        guard mipmapCount > 0, mipmapCount <= 32 else {
            throw SceneTextureError.invalidCount(mipmapCount)
        }
        var selected: SceneTextureMipmap?
        for _ in 0..<mipmapCount {
            let mipmap = try readMipmap(from: &reader)
            if selected == nil || max(mipmap.width, mipmap.height) >= maximumDimension {
                selected = mipmap
            }
        }
        guard let selected else {
            throw SceneTextureError.invalidCount(mipmapCount)
        }
        return selected
    }

    private func readMipmap(from reader: inout SceneTextureBinaryReader) throws -> SceneTextureMipmap {
        let width = try reader.readInt()
        let height = try reader.readInt()
        if container == "TEXB0001" {
            let byteCount = try reader.readInt()
            return SceneTextureMipmap(
                width: width,
                height: height,
                compressed: false,
                decompressedSize: nil,
                data: try reader.readData(count: byteCount)
            )
        }
        let lz4Flag = try reader.readInt()
        let decompressedSize = try reader.readInt()
        let byteCount = try reader.readInt()
        return SceneTextureMipmap(
            width: width,
            height: height,
            compressed: lz4Flag != 0,
            decompressedSize: decompressedSize,
            data: try reader.readData(count: byteCount)
        )
    }
}

struct SceneTextureBinaryReader {
    let data: Data
    var offset = 0

    mutating func readInt() throws -> Int {
        guard data.count - offset >= 4 else {
            throw SceneTextureError.truncatedTexture
        }
        let value = data.withUnsafeBytes { rawBuffer in
            rawBuffer.loadUnaligned(fromByteOffset: offset, as: Int32.self)
        }
        offset += 4
        return Int(Int32(littleEndian: value))
    }

    mutating func readUInt16() throws -> UInt16 {
        guard data.count - offset >= 2 else {
            throw SceneTextureError.truncatedTexture
        }
        let value = data.withUnsafeBytes { rawBuffer in
            rawBuffer.loadUnaligned(fromByteOffset: offset, as: UInt16.self)
        }
        offset += 2
        return UInt16(littleEndian: value)
    }

    mutating func readUInt32() throws -> UInt32 {
        guard data.count - offset >= 4 else {
            throw SceneTextureError.truncatedTexture
        }
        let value = data.withUnsafeBytes { rawBuffer in
            rawBuffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
        }
        offset += 4
        return UInt32(littleEndian: value)
    }

    mutating func readFloat() throws -> Float {
        Float(bitPattern: try readUInt32())
    }

    mutating func readData(count: Int) throws -> Data {
        guard count >= 0, data.count - offset >= count else {
            throw SceneTextureError.truncatedTexture
        }
        let range = offset..<(offset + count)
        offset += count
        return data.subdata(in: range)
    }

    mutating func readCString(maxLength: Int) throws -> String {
        let start = offset
        while offset < data.count, offset - start <= maxLength {
            if data[offset] == 0 {
                let range = start..<offset
                offset += 1
                guard let string = String(data: data[range], encoding: .utf8) else {
                    throw SceneTextureError.invalidString
                }
                return string
            }
            offset += 1
        }
        throw SceneTextureError.invalidString
    }
}
