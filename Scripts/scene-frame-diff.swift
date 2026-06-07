#!/usr/bin/env swift

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

private struct RGBAImage {
    let width: Int
    let height: Int
    let bytes: [UInt8]
}

private struct DiffSummary {
    let width: Int
    let height: Int
    let changedPixelCount: Int
    let totalPixelCount: Int
    let changedRatio: Double
    let averageAbsDelta: Double
    let maxAbsDelta: Int
    let blackRatioA: Double
    let blackRatioB: Double

    var text: String {
        [
            "width=\(width)",
            "height=\(height)",
            "changedPixelCount=\(changedPixelCount)",
            "totalPixelCount=\(totalPixelCount)",
            "changedRatio=\(Self.format(changedRatio))",
            "averageAbsDelta=\(Self.format(averageAbsDelta))",
            "maxAbsDelta=\(maxAbsDelta)",
            "blackRatioA=\(Self.format(blackRatioA))",
            "blackRatioB=\(Self.format(blackRatioB))"
        ].joined(separator: "\n")
    }

    var json: String {
        """
        {
          "width": \(width),
          "height": \(height),
          "changedPixelCount": \(changedPixelCount),
          "totalPixelCount": \(totalPixelCount),
          "changedRatio": \(Self.format(changedRatio)),
          "averageAbsDelta": \(Self.format(averageAbsDelta)),
          "maxAbsDelta": \(maxAbsDelta),
          "blackRatioA": \(Self.format(blackRatioA)),
          "blackRatioB": \(Self.format(blackRatioB))
        }
        """
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.6f", value)
    }
}

private enum FrameDiffError: Error, CustomStringConvertible {
    case usage
    case missingValue(String)
    case invalidInteger(String)
    case invalidDouble(String)
    case invalidMode(String)
    case unreadableImage(String)
    case imageDecodeFailed(String)
    case invalidImageDimensions(width: Int, height: Int)
    case imageTooLarge(width: Int, height: Int, maximumPixels: Int)
    case imageByteCountOverflow(width: Int, height: Int)
    case incompatibleDimensions(aWidth: Int, aHeight: Int, bWidth: Int, bHeight: Int)
    case couldNotCreateFixture(String)
    case minChangedPixelsFailed(actual: Int, expected: Int)
    case maxBlackRatioFailed(actual: Double, maximum: Double)

    var description: String {
        switch self {
        case .usage:
            return """
            usage:
              scene-frame-diff.swift <frame-a.png> <frame-b.png> [--min-changed-pixels N] [--max-black-ratio R] [--json]
              scene-frame-diff.swift --make-fixtures <frame-a.png> <frame-b.png> --mode same|different|black
            """
        case .missingValue(let flag):
            return "missing value for \(flag)"
        case .invalidInteger(let value):
            return "invalid integer: \(value)"
        case .invalidDouble(let value):
            return "invalid number: \(value)"
        case .invalidMode(let value):
            return "invalid fixture mode: \(value)"
        case .unreadableImage(let path):
            return "could not read image: \(path)"
        case .imageDecodeFailed(let path):
            return "could not decode image pixels: \(path)"
        case .invalidImageDimensions(let width, let height):
            return "invalid image dimensions: \(width)x\(height)"
        case .imageTooLarge(let width, let height, let maximumPixels):
            return "image \(width)x\(height) exceeds maximum \(maximumPixels) pixels"
        case .imageByteCountOverflow(let width, let height):
            return "image \(width)x\(height) byte count overflows Int"
        case .incompatibleDimensions(let aWidth, let aHeight, let bWidth, let bHeight):
            return "image sizes differ: \(aWidth)x\(aHeight) vs \(bWidth)x\(bHeight)"
        case .couldNotCreateFixture(let path):
            return "could not create fixture image: \(path)"
        case .minChangedPixelsFailed(let actual, let expected):
            return "changedPixelCount \(actual) is lower than required minimum \(expected)"
        case .maxBlackRatioFailed(let actual, let maximum):
            return "black ratio \(String(format: "%.6f", actual)) exceeds maximum \(String(format: "%.6f", maximum))"
        }
    }
}

private enum FixtureMode: String {
    case same
    case different
    case black
}

private struct Options {
    var imageA: String?
    var imageB: String?
    var makeFixtures = false
    var mode: FixtureMode?
    var minChangedPixels: Int?
    var maxBlackRatio: Double?
    var outputJSON = false
}

private let maximumImagePixels = 18_000_000

private func parseOptions(_ rawArguments: [String]) throws -> Options {
    var arguments = rawArguments
    var options = Options()
    var positional: [String] = []

    while !arguments.isEmpty {
        let argument = arguments.removeFirst()
        switch argument {
        case "--make-fixtures":
            options.makeFixtures = true
            guard arguments.count >= 2 else {
                throw FrameDiffError.missingValue(argument)
            }
            positional.append(arguments.removeFirst())
            positional.append(arguments.removeFirst())
        case "--mode":
            guard let value = arguments.first else {
                throw FrameDiffError.missingValue(argument)
            }
            arguments.removeFirst()
            guard let mode = FixtureMode(rawValue: value) else {
                throw FrameDiffError.invalidMode(value)
            }
            options.mode = mode
        case "--min-changed-pixels":
            guard let value = arguments.first else {
                throw FrameDiffError.missingValue(argument)
            }
            arguments.removeFirst()
            guard let parsed = Int(value), parsed >= 0 else {
                throw FrameDiffError.invalidInteger(value)
            }
            options.minChangedPixels = parsed
        case "--max-black-ratio":
            guard let value = arguments.first else {
                throw FrameDiffError.missingValue(argument)
            }
            arguments.removeFirst()
            guard let parsed = Double(value), parsed >= 0, parsed <= 1 else {
                throw FrameDiffError.invalidDouble(value)
            }
            options.maxBlackRatio = parsed
        case "--json":
            options.outputJSON = true
        default:
            positional.append(argument)
        }
    }

    guard positional.count == 2 else {
        throw FrameDiffError.usage
    }
    options.imageA = positional[0]
    options.imageB = positional[1]

    if options.makeFixtures, options.mode == nil {
        throw FrameDiffError.missingValue("--mode")
    }
    if !options.makeFixtures, options.mode != nil {
        throw FrameDiffError.usage
    }

    return options
}

private func loadImage(path: String) throws -> RGBAImage {
    let url = URL(fileURLWithPath: path)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
        throw FrameDiffError.unreadableImage(path)
    }
    guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw FrameDiffError.imageDecodeFailed(path)
    }

    let width = image.width
    let height = image.height
    _ = try checkedPixelCount(width: width, height: height)
    let bytesPerRow = try checkedByteCount(width: width, height: 1)
    let byteCount = try checkedByteCount(width: width, height: height)
    var bytes = [UInt8](repeating: 0, count: byteCount)
    guard let context = CGContext(
        data: &bytes,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw FrameDiffError.imageDecodeFailed(path)
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    return RGBAImage(width: width, height: height, bytes: bytes)
}

private func checkedPixelCount(width: Int, height: Int) throws -> Int {
    guard width > 0, height > 0 else {
        throw FrameDiffError.invalidImageDimensions(width: width, height: height)
    }
    let product = width.multipliedReportingOverflow(by: height)
    guard !product.overflow else {
        throw FrameDiffError.imageByteCountOverflow(width: width, height: height)
    }
    guard product.partialValue <= maximumImagePixels else {
        throw FrameDiffError.imageTooLarge(width: width, height: height, maximumPixels: maximumImagePixels)
    }
    return product.partialValue
}

private func checkedByteCount(width: Int, height: Int) throws -> Int {
    let row = width.multipliedReportingOverflow(by: 4)
    guard !row.overflow else {
        throw FrameDiffError.imageByteCountOverflow(width: width, height: height)
    }
    let total = row.partialValue.multipliedReportingOverflow(by: height)
    guard !total.overflow else {
        throw FrameDiffError.imageByteCountOverflow(width: width, height: height)
    }
    return total.partialValue
}

private func diff(_ a: RGBAImage, _ b: RGBAImage) throws -> DiffSummary {
    guard a.width == b.width, a.height == b.height else {
        throw FrameDiffError.incompatibleDimensions(
            aWidth: a.width,
            aHeight: a.height,
            bWidth: b.width,
            bHeight: b.height
        )
    }

    let totalPixels = a.width * a.height
    var changedPixels = 0
    var totalAbsDelta = 0
    var maxAbsDelta = 0
    var blackPixelsA = 0
    var blackPixelsB = 0

    for pixelIndex in 0..<totalPixels {
        let offset = pixelIndex * 4
        let aR = Int(a.bytes[offset])
        let aG = Int(a.bytes[offset + 1])
        let aB = Int(a.bytes[offset + 2])
        let bR = Int(b.bytes[offset])
        let bG = Int(b.bytes[offset + 1])
        let bB = Int(b.bytes[offset + 2])
        let deltaR = abs(aR - bR)
        let deltaG = abs(aG - bG)
        let deltaB = abs(aB - bB)
        let pixelDelta = deltaR + deltaG + deltaB
        let maxChannelDelta = max(deltaR, deltaG, deltaB)

        if maxChannelDelta > 0 {
            changedPixels += 1
        }
        totalAbsDelta += pixelDelta
        maxAbsDelta = max(maxAbsDelta, maxChannelDelta)

        if aR < 16, aG < 16, aB < 16 {
            blackPixelsA += 1
        }
        if bR < 16, bG < 16, bB < 16 {
            blackPixelsB += 1
        }
    }

    let denominator = Double(max(totalPixels, 1))
    return DiffSummary(
        width: a.width,
        height: a.height,
        changedPixelCount: changedPixels,
        totalPixelCount: totalPixels,
        changedRatio: Double(changedPixels) / denominator,
        averageAbsDelta: Double(totalAbsDelta) / (denominator * 3),
        maxAbsDelta: maxAbsDelta,
        blackRatioA: Double(blackPixelsA) / denominator,
        blackRatioB: Double(blackPixelsB) / denominator
    )
}

private func writePNG(path: String, width: Int, height: Int, bytes: [UInt8]) throws {
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    var mutableBytes = bytes
    guard let context = CGContext(
        data: &mutableBytes,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ),
        let image = context.makeImage(),
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        )
    else {
        throw FrameDiffError.couldNotCreateFixture(path)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw FrameDiffError.couldNotCreateFixture(path)
    }
}

private func fixtureBytes(mode: FixtureMode, variant: Int) -> [UInt8] {
    switch mode {
    case .same:
        return [
            18, 22, 36, 255, 48, 60, 82, 255, 88, 120, 140, 255, 130, 170, 190, 255,
            22, 34, 48, 255, 56, 72, 94, 255, 96, 132, 150, 255, 140, 182, 202, 255,
            30, 42, 58, 255, 64, 82, 104, 255, 108, 144, 162, 255, 150, 194, 214, 255,
            42, 54, 70, 255, 78, 96, 116, 255, 120, 156, 174, 255, 162, 206, 226, 255
        ]
    case .different:
        let a: [UInt8] = [
            18, 22, 36, 255, 48, 60, 82, 255, 88, 120, 140, 255, 130, 170, 190, 255,
            22, 34, 48, 255, 56, 72, 94, 255, 96, 132, 150, 255, 140, 182, 202, 255,
            30, 42, 58, 255, 64, 82, 104, 255, 108, 144, 162, 255, 150, 194, 214, 255,
            42, 54, 70, 255, 78, 96, 116, 255, 120, 156, 174, 255, 162, 206, 226, 255
        ]
        let b: [UInt8] = [
            24, 30, 42, 255, 52, 68, 100, 255, 120, 152, 170, 255, 138, 178, 206, 255,
            28, 40, 54, 255, 72, 92, 118, 255, 112, 154, 176, 255, 148, 194, 222, 255,
            44, 58, 74, 255, 84, 112, 136, 255, 132, 172, 196, 255, 168, 214, 234, 255,
            60, 76, 94, 255, 96, 122, 146, 255, 142, 182, 204, 255, 190, 228, 246, 255
        ]
        return variant == 0 ? a : b
    case .black:
        return [UInt8](repeating: 0, count: 4 * 4 * 4).enumerated().map { index, value in
            (index + 1).isMultiple(of: 4) ? 255 : value
        }
    }
}

private func makeFixtures(pathA: String, pathB: String, mode: FixtureMode) throws {
    try writePNG(path: pathA, width: 4, height: 4, bytes: fixtureBytes(mode: mode, variant: 0))
    try writePNG(path: pathB, width: 4, height: 4, bytes: fixtureBytes(mode: mode, variant: 1))
}

private func validate(_ summary: DiffSummary, options: Options) throws {
    if let minChangedPixels = options.minChangedPixels,
       summary.changedPixelCount < minChangedPixels {
        throw FrameDiffError.minChangedPixelsFailed(
            actual: summary.changedPixelCount,
            expected: minChangedPixels
        )
    }

    if let maxBlackRatio = options.maxBlackRatio {
        let worstBlackRatio = max(summary.blackRatioA, summary.blackRatioB)
        if worstBlackRatio > maxBlackRatio {
            throw FrameDiffError.maxBlackRatioFailed(
                actual: worstBlackRatio,
                maximum: maxBlackRatio
            )
        }
    }
}

private func main() throws {
    let options = try parseOptions(Array(CommandLine.arguments.dropFirst()))
    guard let imageA = options.imageA, let imageB = options.imageB else {
        throw FrameDiffError.usage
    }

    if options.makeFixtures {
        guard let mode = options.mode else {
            throw FrameDiffError.missingValue("--mode")
        }
        try makeFixtures(pathA: imageA, pathB: imageB, mode: mode)
        print("fixturesWritten=2")
        print("mode=\(mode.rawValue)")
        print("pathA=\(imageA)")
        print("pathB=\(imageB)")
        return
    }

    let summary = try diff(try loadImage(path: imageA), try loadImage(path: imageB))
    try validate(summary, options: options)
    print(options.outputJSON ? summary.json : summary.text)
}

do {
    try main()
} catch let error as FrameDiffError {
    fputs("\(error.description)\n", stderr)
    exit(2)
} catch {
    fputs("\(error)\n", stderr)
    exit(1)
}
