import Foundation

public struct SceneTexture: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let storage: SceneTextureStorage

    public init(width: Int, height: Int, storage: SceneTextureStorage) {
        self.width = width
        self.height = height
        self.storage = storage
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
        guard flags & 0x24 == 0 else {
            throw SceneTextureError.unsupportedTextureFlags(flags)
        }
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
        let mipmap = try SceneTextureMipmapReader(container: container)
            .readBestMipmap(from: &reader, maximumDimension: maximumDisplayDimension)
        let pixelCount = try Self.checkedProduct(mipmap.width, mipmap.height)
        if mipmap.compressed, pixelCount > maximumSoftwareDecodedPixels {
            throw SceneTextureError.textureTooLargeForSoftwareDecode(mipmap.width, mipmap.height)
        }
        let payload = try decodePayload(mipmap)
        if Self.isEncodedImage(payload) {
            return SceneTexture(width: scaledWidth(imageWidth, textureWidth: textureWidth, mipmapWidth: mipmap.width),
                                height: scaledHeight(imageHeight, textureHeight: textureHeight, mipmapHeight: mipmap.height),
                                storage: .encodedImage(payload))
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
        return SceneTexture(width: targetWidth, height: targetHeight, storage: .rgba(
            width: targetWidth,
            height: targetHeight,
            data: rgba
        ))
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
            return "Unsupported animated or video scene texture flags: \(flags)."
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
        let imageCount = try reader.readInt()
        guard imageCount > 0, imageCount <= 4_096 else {
            throw SceneTextureError.invalidCount(imageCount)
        }
        if container == "TEXB0003" || container == "TEXB0004" {
            _ = try reader.readInt()
        } else if container != "TEXB0001" && container != "TEXB0002" {
            throw SceneTextureError.unsupportedContainer(container)
        }
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
