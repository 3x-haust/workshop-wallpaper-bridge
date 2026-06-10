import Foundation

enum Fixture {
    static func makeTempDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "wwb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func makeWorkshopRoot() throws -> URL {
        let root = try makeTempDirectory()
            .appending(path: "steamapps")
            .appending(path: "workshop")
            .appending(path: "content")
            .appending(path: "431960")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func project(root: URL, id: String, metadata: String, file: String) throws {
        let project = root.appending(path: id)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try metadata.write(to: project.appending(path: "project.json"), atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: project.appending(path: file).path, contents: Data())
    }

    static func writeScenePackage(
        to url: URL,
        sceneJSON: String,
        extraEntries: [(path: String, data: Data)] = []
    ) throws {
        var entries = [(path: "scene.json", data: Data(sceneJSON.utf8))]
        entries.append(contentsOf: extraEntries)
        try scenePackageData(entries: entries).write(to: url, options: [.atomic])
    }

    static func scenePackageData(
        magic: String = "PKGV0007",
        entries: [(path: String, data: Data)]
    ) -> Data {
        var data = Data()
        data.appendLengthPrefixedString(magic)
        data.appendInt32(entries.count)
        var offset = 0
        for entry in entries {
            data.appendLengthPrefixedString(entry.path)
            data.appendInt32(offset)
            data.appendInt32(entry.data.count)
            offset += entry.data.count
        }
        for entry in entries {
            data.append(entry.data)
        }
        return data
    }

    struct TexFrame {
        let imageId: Int
        let frametime: Float
        let x: Double
        let y: Double
        let width: Double
        let widthY: Double
        let heightX: Double
        let height: Double

        init(
            imageId: Int = 0,
            frametime: Float,
            x: Double,
            y: Double,
            width: Double,
            widthY: Double = 0,
            heightX: Double = 0,
            height: Double
        ) {
            self.imageId = imageId
            self.frametime = frametime
            self.x = x
            self.y = y
            self.width = width
            self.widthY = widthY
            self.heightX = heightX
            self.height = height
        }
    }

    // swiftlint:disable:next function_parameter_count
    static func animatedTexData(
        textureWidth: Int,
        textureHeight: Int,
        flags: Int = 4,
        format: Int = 0,
        container: String = "TEXB0002",
        isVideoMP4: Bool = false,
        mipmaps: [(width: Int, height: Int, data: Data)],
        frameContainer: String? = "TEXS0002",
        gifSize: (width: Int, height: Int)? = nil,
        frames: [TexFrame] = []
    ) -> Data {
        var data = Data()
        data.appendNullTerminatedString("TEXV0005")
        data.appendNullTerminatedString("TEXI0001")
        data.appendInt32(format)
        data.appendInt32(flags)
        data.appendInt32(textureWidth)
        data.appendInt32(textureHeight)
        data.appendInt32(textureWidth)
        data.appendInt32(textureHeight)
        data.appendUInt32(0)
        data.appendNullTerminatedString(container)
        data.appendInt32(1)
        if container == "TEXB0003" {
            data.appendInt32(0)
        } else if container == "TEXB0004" {
            data.appendInt32(0)
            data.appendInt32(isVideoMP4 ? 1 : 0)
        }
        data.appendInt32(mipmaps.count)
        for mipmap in mipmaps {
            data.appendInt32(mipmap.width)
            data.appendInt32(mipmap.height)
            if container != "TEXB0001" {
                data.appendInt32(0)
                data.appendInt32(0)
            }
            data.appendInt32(mipmap.data.count)
            data.append(mipmap.data)
        }
        guard let frameContainer else {
            return data
        }
        data.appendNullTerminatedString(frameContainer)
        data.appendInt32(frames.count)
        if frameContainer == "TEXS0003" {
            data.appendInt32(gifSize?.width ?? 0)
            data.appendInt32(gifSize?.height ?? 0)
        }
        for frame in frames {
            data.appendInt32(frame.imageId)
            data.appendFloat(frame.frametime)
            let geometry = [frame.x, frame.y, frame.width, frame.widthY, frame.heightX, frame.height]
            for value in geometry {
                if frameContainer == "TEXS0001" {
                    data.appendInt32(Int(value))
                } else {
                    data.appendFloat(Float(value))
                }
            }
        }
        return data
    }

    static func texData(
        width: Int,
        height: Int,
        imageFormat: Int = 13,
        imageData: Data
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
        data.appendInt32(imageFormat)
        data.appendInt32(1)
        data.appendInt32(width)
        data.appendInt32(height)
        data.appendInt32(0)
        data.appendInt32(0)
        data.appendInt32(imageData.count)
        data.append(imageData)
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

    mutating func appendFloat(_ value: Float) {
        var raw = value.bitPattern.littleEndian
        Swift.withUnsafeBytes(of: &raw) { append(contentsOf: $0) }
    }

    mutating func appendLengthPrefixedString(_ string: String) {
        let bytes = Data(string.utf8)
        appendInt32(bytes.count)
        append(bytes)
    }

    mutating func appendNullTerminatedString(_ string: String) {
        append(Data(string.utf8))
        append(0)
    }
}
