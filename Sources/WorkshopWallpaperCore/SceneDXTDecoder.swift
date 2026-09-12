import Foundation
// swiftlint:disable function_parameter_count identifier_name

struct SceneDXTDecoder: Sendable {
    enum Format: Sendable {
        case dxt1
        case dxt3
        case dxt5
    }

    let format: Format

    /// Decode one bounded block at a time into a reduced sheet. Never allocates
    /// a full-resolution RGBA copy of a large sprite atlas.
    func decodeReduced(_ data: Data, width: Int, height: Int, step: Int) throws -> Data {
        guard width > 0, height > 0, width <= 16384, height <= 16384,
              step >= 4, step <= 16384, step % 4 == 0 else { throw SceneTextureError.invalidDimensions }
        let blocksWide = (width + 3) / 4, blocksHigh = (height + 3) / 4
        let blockSize = format == .dxt1 ? 8 : 16
        guard data.count >= blocksWide * blocksHigh * blockSize else { throw SceneTextureError.truncatedTexture }
        let outputWidth = (width + step - 1) / step, outputHeight = (height + step - 1) / step
        guard outputWidth * outputHeight <= 18_000_000 else { throw SceneTextureError.textureTooLargeForSoftwareDecode(width, height) }
        var output = Data(count: outputWidth * outputHeight * 4)
        var block = [UInt8](repeating: 0, count: 64)
        for y in 0..<outputHeight {
            for x in 0..<outputWidth {
                let offset = ((y * step / 4) * blocksWide + x * step / 4) * blockSize
                try decodeBlock(data: data, offset: offset, into: &block, width: 4, height: 4, blockX: 0, blockY: 0)
                let destination = (y * outputWidth + x) * 4
                for channel in 0..<4 { output[destination + channel] = block[channel] }
            }
        }
        return output
    }

    func decode(_ data: Data, width: Int, height: Int) throws -> Data {
        guard width > 0, height > 0 else {
            throw SceneTextureError.invalidDimensions
        }
        let blocksWide = (width + 3) / 4
        let blocksHigh = (height + 3) / 4
        let blockSize = format == .dxt1 ? 8 : 16
        guard data.count >= blocksWide * blocksHigh * blockSize else {
            throw SceneTextureError.truncatedTexture
        }

        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        var offset = 0
        for blockY in 0..<blocksHigh {
            for blockX in 0..<blocksWide {
                try decodeBlock(
                    data: data,
                    offset: offset,
                    into: &rgba,
                    width: width,
                    height: height,
                    blockX: blockX,
                    blockY: blockY
                )
                offset += blockSize
            }
        }
        return Data(rgba)
    }

    private func decodeBlock(
        data: Data,
        offset: Int,
        into rgba: inout [UInt8],
        width: Int,
        height: Int,
        blockX: Int,
        blockY: Int
    ) throws {
        switch format {
        case .dxt1:
            try decodeColorBlock(
                data: data,
                offset: offset,
                alpha: nil,
                allowOneBitAlpha: true,
                into: &rgba,
                width: width,
                height: height,
                blockX: blockX,
                blockY: blockY
            )
        case .dxt3:
            let alpha = decodeDXT3Alpha(data: data, offset: offset)
            try decodeColorBlock(
                data: data,
                offset: offset + 8,
                alpha: alpha,
                allowOneBitAlpha: false,
                into: &rgba,
                width: width,
                height: height,
                blockX: blockX,
                blockY: blockY
            )
        case .dxt5:
            let alpha = decodeDXT5Alpha(data: data, offset: offset)
            try decodeColorBlock(
                data: data,
                offset: offset + 8,
                alpha: alpha,
                allowOneBitAlpha: false,
                into: &rgba,
                width: width,
                height: height,
                blockX: blockX,
                blockY: blockY
            )
        }
    }

    private func decodeColorBlock(
        data: Data,
        offset: Int,
        alpha: [UInt8]?,
        allowOneBitAlpha: Bool,
        into rgba: inout [UInt8],
        width: Int,
        height: Int,
        blockX: Int,
        blockY: Int
    ) throws {
        var reader = SceneTextureBinaryReader(data: data, offset: offset)
        let color0 = try reader.readUInt16()
        let color1 = try reader.readUInt16()
        let lookup = try reader.readUInt32()
        let colors = colorPalette(color0: color0, color1: color1, allowOneBitAlpha: allowOneBitAlpha)
        for localY in 0..<4 {
            let y = blockY * 4 + localY
            guard y < height else {
                continue
            }
            for localX in 0..<4 {
                let x = blockX * 4 + localX
                guard x < width else {
                    continue
                }
                let localIndex = localY * 4 + localX
                let paletteIndex = Int((lookup >> UInt32(localIndex * 2)) & 0x03)
                var pixel = colors[paletteIndex]
                if let alpha {
                    pixel.alpha = alpha[localIndex]
                }
                write(pixel: pixel, into: &rgba, width: width, x: x, y: y)
            }
        }
    }

    private func colorPalette(color0: UInt16, color1: UInt16, allowOneBitAlpha: Bool) -> [SceneRGBA] {
        let first = rgb565(color0)
        let second = rgb565(color1)
        if color0 > color1 || !allowOneBitAlpha {
            return [
                first,
                second,
                SceneRGBA.interpolate(first, second, firstWeight: 2, secondWeight: 1, divisor: 3),
                SceneRGBA.interpolate(first, second, firstWeight: 1, secondWeight: 2, divisor: 3)
            ]
        }
        return [
            first,
            second,
            SceneRGBA.interpolate(first, second, firstWeight: 1, secondWeight: 1, divisor: 2),
            SceneRGBA(red: 0, green: 0, blue: 0, alpha: 0)
        ]
    }

    private func rgb565(_ value: UInt16) -> SceneRGBA {
        let red = UInt8(((Int(value >> 11) & 0x1F) * 255 + 15) / 31)
        let green = UInt8(((Int(value >> 5) & 0x3F) * 255 + 31) / 63)
        let blue = UInt8((Int(value & 0x1F) * 255 + 15) / 31)
        return SceneRGBA(red: red, green: green, blue: blue, alpha: 255)
    }

    private func decodeDXT3Alpha(data: Data, offset: Int) -> [UInt8] {
        var values: [UInt8] = []
        values.reserveCapacity(16)
        for byte in data[offset..<(offset + 8)] {
            values.append(UInt8(Int(byte & 0x0F) * 17))
            values.append(UInt8(Int(byte >> 4) * 17))
        }
        return values
    }

    private func decodeDXT5Alpha(data: Data, offset: Int) -> [UInt8] {
        let alpha0 = data[offset]
        let alpha1 = data[offset + 1]
        let palette = alphaPalette(alpha0: alpha0, alpha1: alpha1)
        var bits: UInt64 = 0
        for index in 0..<6 {
            bits |= UInt64(data[offset + 2 + index]) << UInt64(index * 8)
        }
        return (0..<16).map { index in
            let paletteIndex = Int((bits >> UInt64(index * 3)) & 0x07)
            return palette[paletteIndex]
        }
    }

    private func alphaPalette(alpha0: UInt8, alpha1: UInt8) -> [UInt8] {
        if alpha0 > alpha1 {
            return [
                alpha0,
                alpha1,
                weightedAlpha(alpha0, alpha1, firstWeight: 6, secondWeight: 1, divisor: 7),
                weightedAlpha(alpha0, alpha1, firstWeight: 5, secondWeight: 2, divisor: 7),
                weightedAlpha(alpha0, alpha1, firstWeight: 4, secondWeight: 3, divisor: 7),
                weightedAlpha(alpha0, alpha1, firstWeight: 3, secondWeight: 4, divisor: 7),
                weightedAlpha(alpha0, alpha1, firstWeight: 2, secondWeight: 5, divisor: 7),
                weightedAlpha(alpha0, alpha1, firstWeight: 1, secondWeight: 6, divisor: 7)
            ]
        }
        return [
            alpha0,
            alpha1,
            weightedAlpha(alpha0, alpha1, firstWeight: 4, secondWeight: 1, divisor: 5),
            weightedAlpha(alpha0, alpha1, firstWeight: 3, secondWeight: 2, divisor: 5),
            weightedAlpha(alpha0, alpha1, firstWeight: 2, secondWeight: 3, divisor: 5),
            weightedAlpha(alpha0, alpha1, firstWeight: 1, secondWeight: 4, divisor: 5),
            0,
            255
        ]
    }

    private func weightedAlpha(
        _ first: UInt8,
        _ second: UInt8,
        firstWeight: Int,
        secondWeight: Int,
        divisor: Int
    ) -> UInt8 {
        UInt8((Int(first) * firstWeight + Int(second) * secondWeight) / divisor)
    }

    private func write(pixel: SceneRGBA, into rgba: inout [UInt8], width: Int, x: Int, y: Int) {
        let index = (y * width + x) * 4
        rgba[index] = pixel.red
        rgba[index + 1] = pixel.green
        rgba[index + 2] = pixel.blue
        rgba[index + 3] = pixel.alpha
    }
}

private struct SceneRGBA {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
    var alpha: UInt8

    static func interpolate(
        _ first: SceneRGBA,
        _ second: SceneRGBA,
        firstWeight: Int,
        secondWeight: Int,
        divisor: Int
    ) -> SceneRGBA {
        SceneRGBA(
            red: weighted(first.red, second.red, firstWeight: firstWeight, secondWeight: secondWeight, divisor: divisor),
            green: weighted(
                first.green,
                second.green,
                firstWeight: firstWeight,
                secondWeight: secondWeight,
                divisor: divisor
            ),
            blue: weighted(
                first.blue,
                second.blue,
                firstWeight: firstWeight,
                secondWeight: secondWeight,
                divisor: divisor
            ),
            alpha: 255
        )
    }

    private static func weighted(
        _ first: UInt8,
        _ second: UInt8,
        firstWeight: Int,
        secondWeight: Int,
        divisor: Int
    ) -> UInt8 {
        UInt8((Int(first) * firstWeight + Int(second) * secondWeight) / divisor)
    }
}
