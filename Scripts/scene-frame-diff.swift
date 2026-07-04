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

private struct PixelRect {
    let x: Int
    let y: Int
    let width: Int
    let height: Int

    func contains(x px: Int, y py: Int) -> Bool {
        px >= x && py >= y && px < x + width && py < y + height
    }
}

private struct DiffSummary {
    let width: Int
    let height: Int
    let changedPixelCount: Int
    let totalPixelCount: Int
    let changedRatio: Double
    let averageAbsDelta: Double
    let averageDeltaR: Double
    let averageDeltaG: Double
    let averageDeltaB: Double
    let maxAbsDelta: Int
    let blackRatioA: Double
    let blackRatioB: Double
    let highlightPixelCountA: Int
    let highlightPixelCountB: Int
    let brightHighlightClusterCountA: Int
    let brightHighlightClusterCountB: Int
    let staticCropAverageDeltaR: Double
    let staticCropAverageDeltaG: Double
    let staticCropAverageDeltaB: Double
    let motionEnergyA: Double
    let motionEnergyB: Double
    let gradientOutlierPixelCount: Int

    var text: String {
        [
            "width=\(width)",
            "height=\(height)",
            "changedPixelCount=\(changedPixelCount)",
            "totalPixelCount=\(totalPixelCount)",
            "changedRatio=\(Self.format(changedRatio))",
            "averageAbsDelta=\(Self.format(averageAbsDelta))",
            "averageDeltaR=\(Self.format(averageDeltaR))",
            "averageDeltaG=\(Self.format(averageDeltaG))",
            "averageDeltaB=\(Self.format(averageDeltaB))",
            "maxAbsDelta=\(maxAbsDelta)",
            "blackRatioA=\(Self.format(blackRatioA))",
            "blackRatioB=\(Self.format(blackRatioB))",
            "highlightPixelCountA=\(highlightPixelCountA)",
            "highlightPixelCountB=\(highlightPixelCountB)",
            "brightHighlightClusterCountA=\(brightHighlightClusterCountA)",
            "brightHighlightClusterCountB=\(brightHighlightClusterCountB)",
            "staticCropAverageDeltaR=\(Self.format(staticCropAverageDeltaR))",
            "staticCropAverageDeltaG=\(Self.format(staticCropAverageDeltaG))",
            "staticCropAverageDeltaB=\(Self.format(staticCropAverageDeltaB))",
            "motionEnergyA=\(Self.format(motionEnergyA))",
            "motionEnergyB=\(Self.format(motionEnergyB))",
            "gradientOutlierPixelCount=\(gradientOutlierPixelCount)"
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
          "averageDeltaR": \(Self.format(averageDeltaR)),
          "averageDeltaG": \(Self.format(averageDeltaG)),
          "averageDeltaB": \(Self.format(averageDeltaB)),
          "maxAbsDelta": \(maxAbsDelta),
          "blackRatioA": \(Self.format(blackRatioA)),
          "blackRatioB": \(Self.format(blackRatioB)),
          "highlightPixelCountA": \(highlightPixelCountA),
          "highlightPixelCountB": \(highlightPixelCountB),
          "brightHighlightClusterCountA": \(brightHighlightClusterCountA),
          "brightHighlightClusterCountB": \(brightHighlightClusterCountB),
          "staticCropAverageDeltaR": \(Self.format(staticCropAverageDeltaR)),
          "staticCropAverageDeltaG": \(Self.format(staticCropAverageDeltaG)),
          "staticCropAverageDeltaB": \(Self.format(staticCropAverageDeltaB)),
          "motionEnergyA": \(Self.format(motionEnergyA)),
          "motionEnergyB": \(Self.format(motionEnergyB)),
          "gradientOutlierPixelCount": \(gradientOutlierPixelCount)
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
    case invalidRect(String)
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
              scene-frame-diff.swift <frame-a.png> <frame-b.png> [--min-changed-pixels N] [--max-black-ratio R] [--static-crop x,y,width,height] [--mask-rect x,y,width,height] [--previous-a frame.png] [--previous-b frame.png] [--json]
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
        case .invalidRect(let value):
            return "invalid rect: \(value) (expected x,y,width,height)"
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
    var staticCrop: PixelRect?
    var maskRect: PixelRect?
    var previousImageA: String?
    var previousImageB: String?
    var outputJSON = false
}

private let maximumImagePixels = 18_000_000
private let blackChannelThreshold = 16
private let highlightChannelThreshold = 224
private let gradientOutlierDeltaThreshold = 0

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
        case "--static-crop":
            guard let value = arguments.first else {
                throw FrameDiffError.missingValue(argument)
            }
            arguments.removeFirst()
            options.staticCrop = try parseRect(value)
        case "--mask-rect":
            guard let value = arguments.first else {
                throw FrameDiffError.missingValue(argument)
            }
            arguments.removeFirst()
            options.maskRect = try parseRect(value)
        case "--previous-a":
            guard let value = arguments.first else {
                throw FrameDiffError.missingValue(argument)
            }
            arguments.removeFirst()
            options.previousImageA = value
        case "--previous-b":
            guard let value = arguments.first else {
                throw FrameDiffError.missingValue(argument)
            }
            arguments.removeFirst()
            options.previousImageB = value
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

private func parseRect(_ raw: String) throws -> PixelRect {
    let parts = raw.split(separator: ",").map(String.init)
    guard parts.count == 4,
          let x = Int(parts[0]), x >= 0,
          let y = Int(parts[1]), y >= 0,
          let width = Int(parts[2]), width > 0,
          let height = Int(parts[3]), height > 0 else {
        throw FrameDiffError.invalidRect(raw)
    }
    return PixelRect(x: x, y: y, width: width, height: height)
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

private func diff(_ a: RGBAImage, _ b: RGBAImage, options: Options) throws -> DiffSummary {
    guard a.width == b.width, a.height == b.height else {
        throw FrameDiffError.incompatibleDimensions(
            aWidth: a.width,
            aHeight: a.height,
            bWidth: b.width,
            bHeight: b.height
        )
    }

    var changedPixels = 0
    var comparedPixels = 0
    var totalAbsDelta = 0
    var totalDeltaR = 0
    var totalDeltaG = 0
    var totalDeltaB = 0
    var maxAbsDelta = 0
    var blackPixelsA = 0
    var blackPixelsB = 0
    var highlightPixelsA = 0
    var highlightPixelsB = 0
    let staticCrop = clipped(options.staticCrop ?? PixelRect(x: 0, y: 0, width: a.width, height: a.height), to: a)
    var cropPixels = 0
    var cropDeltaR = 0
    var cropDeltaG = 0
    var cropDeltaB = 0

    for y in 0..<a.height {
        for x in 0..<a.width {
            guard isIncluded(x: x, y: y, mask: options.maskRect) else {
                continue
            }
            let pixelIndex = (y * a.width) + x
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

            comparedPixels += 1
            if maxChannelDelta > 0 {
                changedPixels += 1
            }
            totalAbsDelta += pixelDelta
            totalDeltaR += deltaR
            totalDeltaG += deltaG
            totalDeltaB += deltaB
            maxAbsDelta = max(maxAbsDelta, maxChannelDelta)

            if aR < blackChannelThreshold, aG < blackChannelThreshold, aB < blackChannelThreshold {
                blackPixelsA += 1
            }
            if bR < blackChannelThreshold, bG < blackChannelThreshold, bB < blackChannelThreshold {
                blackPixelsB += 1
            }
            if aR >= highlightChannelThreshold, aG >= highlightChannelThreshold, aB >= highlightChannelThreshold {
                highlightPixelsA += 1
            }
            if bR >= highlightChannelThreshold, bG >= highlightChannelThreshold, bB >= highlightChannelThreshold {
                highlightPixelsB += 1
            }
            if staticCrop.contains(x: x, y: y) {
                cropPixels += 1
                cropDeltaR += deltaR
                cropDeltaG += deltaG
                cropDeltaB += deltaB
            }
        }
    }

    let denominator = Double(max(comparedPixels, 1))
    let cropDenominator = Double(max(cropPixels, 1))
    return DiffSummary(
        width: a.width,
        height: a.height,
        changedPixelCount: changedPixels,
        totalPixelCount: comparedPixels,
        changedRatio: Double(changedPixels) / denominator,
        averageAbsDelta: Double(totalAbsDelta) / (denominator * 3),
        averageDeltaR: Double(totalDeltaR) / denominator,
        averageDeltaG: Double(totalDeltaG) / denominator,
        averageDeltaB: Double(totalDeltaB) / denominator,
        maxAbsDelta: maxAbsDelta,
        blackRatioA: Double(blackPixelsA) / denominator,
        blackRatioB: Double(blackPixelsB) / denominator,
        highlightPixelCountA: highlightPixelsA,
        highlightPixelCountB: highlightPixelsB,
        brightHighlightClusterCountA: brightHighlightClusterCount(a, mask: options.maskRect),
        brightHighlightClusterCountB: brightHighlightClusterCount(b, mask: options.maskRect),
        staticCropAverageDeltaR: Double(cropDeltaR) / cropDenominator,
        staticCropAverageDeltaG: Double(cropDeltaG) / cropDenominator,
        staticCropAverageDeltaB: Double(cropDeltaB) / cropDenominator,
        motionEnergyA: try motionEnergy(current: a, previousPath: options.previousImageA, mask: options.maskRect),
        motionEnergyB: try motionEnergy(current: b, previousPath: options.previousImageB, mask: options.maskRect),
        gradientOutlierPixelCount: gradientOutlierPixelCount(a, b, mask: options.maskRect)
    )
}

private func clipped(_ rect: PixelRect, to image: RGBAImage) -> PixelRect {
    let x = min(rect.x, image.width)
    let y = min(rect.y, image.height)
    let maxWidth = max(image.width - x, 0)
    let maxHeight = max(image.height - y, 0)
    return PixelRect(x: x, y: y, width: min(rect.width, maxWidth), height: min(rect.height, maxHeight))
}

private func isIncluded(x: Int, y: Int, mask: PixelRect?) -> Bool {
    guard let mask else {
        return true
    }
    return !mask.contains(x: x, y: y)
}

private func gradientOutlierPixelCount(_ a: RGBAImage, _ b: RGBAImage, mask: PixelRect?) -> Int {
    var outliers = 0

    for y in 0..<a.height {
        for x in 0..<a.width {
            guard isIncluded(x: x, y: y, mask: mask) else {
                continue
            }
            let gradientDelta = abs(
                localGradientMagnitude(a, x: x, y: y) - localGradientMagnitude(b, x: x, y: y)
            )
            if gradientDelta > gradientOutlierDeltaThreshold {
                outliers += 1
            }
        }
    }

    return outliers
}

private func brightHighlightClusterCount(_ image: RGBAImage, mask: PixelRect?) -> Int {
    let totalPixels = image.width * image.height
    var visited = [Bool](repeating: false, count: totalPixels)
    var clusters = 0

    for y in 0..<image.height {
        for x in 0..<image.width {
            let index = (y * image.width) + x
            if visited[index] || !isBrightHighlight(image, x: x, y: y) || !isIncluded(x: x, y: y, mask: mask) {
                continue
            }
            clusters += 1
            var stack = [(x, y)]
            visited[index] = true
            while let (cx, cy) = stack.popLast() {
                for (nx, ny) in [(cx + 1, cy), (cx - 1, cy), (cx, cy + 1), (cx, cy - 1)] {
                    guard nx >= 0, ny >= 0, nx < image.width, ny < image.height else {
                        continue
                    }
                    let nextIndex = (ny * image.width) + nx
                    if visited[nextIndex]
                        || !isIncluded(x: nx, y: ny, mask: mask)
                        || !isBrightHighlight(image, x: nx, y: ny) {
                        continue
                    }
                    visited[nextIndex] = true
                    stack.append((nx, ny))
                }
            }
        }
    }

    return clusters
}

private func isBrightHighlight(_ image: RGBAImage, x: Int, y: Int) -> Bool {
    let offset = ((y * image.width) + x) * 4
    return image.bytes[offset] >= highlightChannelThreshold
        && image.bytes[offset + 1] >= highlightChannelThreshold
        && image.bytes[offset + 2] >= highlightChannelThreshold
}

private func motionEnergy(current: RGBAImage, previousPath: String?, mask: PixelRect?) throws -> Double {
    guard let previousPath else {
        return 0
    }
    let previous = try loadImage(path: previousPath)
    guard previous.width == current.width, previous.height == current.height else {
        throw FrameDiffError.incompatibleDimensions(
            aWidth: previous.width,
            aHeight: previous.height,
            bWidth: current.width,
            bHeight: current.height
        )
    }
    var totalDelta = 0
    var comparedPixels = 0
    for y in 0..<current.height {
        for x in 0..<current.width {
            guard isIncluded(x: x, y: y, mask: mask) else {
                continue
            }
            let offset = ((y * current.width) + x) * 4
            totalDelta += rgbDistance(previous.bytes, offset, offsetFor(image: current, x: x, y: y), current.bytes)
            comparedPixels += 1
        }
    }
    return Double(totalDelta) / Double(max(comparedPixels * 3, 1))
}

private func localGradientMagnitude(_ image: RGBAImage, x: Int, y: Int) -> Int {
    let offset = ((y * image.width) + x) * 4
    var magnitude = 0

    if x + 1 < image.width {
        magnitude += rgbDistance(image.bytes, offset, offset + 4)
    }
    if y + 1 < image.height {
        magnitude += rgbDistance(image.bytes, offset, offset + (image.width * 4))
    }

    return magnitude
}

private func rgbDistance(_ bytes: [UInt8], _ lhsOffset: Int, _ rhsOffset: Int) -> Int {
    abs(Int(bytes[lhsOffset]) - Int(bytes[rhsOffset]))
        + abs(Int(bytes[lhsOffset + 1]) - Int(bytes[rhsOffset + 1]))
        + abs(Int(bytes[lhsOffset + 2]) - Int(bytes[rhsOffset + 2]))
}

private func rgbDistance(_ lhs: [UInt8], _ lhsOffset: Int, _ rhsOffset: Int, _ rhs: [UInt8]) -> Int {
    abs(Int(lhs[lhsOffset]) - Int(rhs[rhsOffset]))
        + abs(Int(lhs[lhsOffset + 1]) - Int(rhs[rhsOffset + 1]))
        + abs(Int(lhs[lhsOffset + 2]) - Int(rhs[rhsOffset + 2]))
}

private func offsetFor(image: RGBAImage, x: Int, y: Int) -> Int {
    ((y * image.width) + x) * 4
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

    let summary = try diff(try loadImage(path: imageA), try loadImage(path: imageB), options: options)
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
