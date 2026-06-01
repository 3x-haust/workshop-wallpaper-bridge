import Foundation
import WorkshopWallpaperCore

@main
struct WWBCtl {
    static func main() {
        do {
            try run(arguments: Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            Foundation.exit(1)
        }
    }

    static func run(arguments: [String]) throws {
        guard let command = arguments.first else {
            printHelp()
            return
        }
        switch command {
        case "scan":
            try scan(arguments: Array(arguments.dropFirst()))
        case "import":
            try importAssets(arguments: Array(arguments.dropFirst()))
        case "import-video":
            try importVideo(arguments: Array(arguments.dropFirst()))
        case "remove":
            try remove(arguments: Array(arguments.dropFirst()))
        case "convert":
            try convert(arguments: Array(arguments.dropFirst()))
        case "doctor":
            try doctor()
        case "help", "--help", "-h":
            printHelp()
        default:
            throw CLIError.unknownCommand(command)
        }
    }

    private static func scan(arguments: [String]) throws {
        guard let path = arguments.first else {
            throw CLIError.missingPath
        }
        let result = try WallpaperScanner().scan(root: URL(filePath: path))
        let data = try JSONEncoder.cli.encode(result)
        if let out = optionValue("--out", in: arguments) {
            try data.write(to: URL(filePath: out), options: [.atomic])
        } else {
            FileHandle.standardOutput.write(data)
            print("")
        }
    }

    private static func importAssets(arguments: [String]) throws {
        guard let path = arguments.first else {
            throw CLIError.missingPath
        }
        let store = try store(from: arguments)
        let result = try WallpaperScanner().scan(root: URL(filePath: path))
        let imported = try result.assets.map { try store.importAsset($0) }
        print("imported \(imported.count) asset(s) into \(store.root.path)")
    }

    private static func importVideo(arguments: [String]) throws {
        guard let path = arguments.first else {
            throw CLIError.missingPath
        }
        let store = try store(from: arguments)
        let imported = try store.importVideoFile(URL(filePath: path))
        print("imported \(imported.title) into \(store.root.path)")
    }

    private static func remove(arguments: [String]) throws {
        guard let id = arguments.first else {
            throw CLIError.missingAssetId
        }
        let store = try store(from: arguments)
        try store.removeAsset(id: id)
        print("removed \(id) from \(store.root.path)")
    }

    private static func convert(arguments: [String]) throws {
        guard arguments.count >= 3, arguments[1] == "--out" else {
            throw CLIError.invalidConvertUsage
        }
        try VideoConverter().convertToPlayableVideo(
            input: URL(filePath: arguments[0]),
            output: URL(filePath: arguments[2])
        )
        print("converted \(arguments[2])")
    }

    private static func doctor() throws {
        let store = try LibraryStore.defaultStore()
        let ffmpeg = VideoConverter().ffmpegPath() ?? "not found"
        print("library: \(store.root.path)")
        print("ffmpeg: \(ffmpeg)")
        print("platform: \(ProcessInfo.processInfo.operatingSystemVersionString)")
    }

    private static func store(from arguments: [String]) throws -> LibraryStore {
        if let path = optionValue("--library", in: arguments) {
            return LibraryStore(root: URL(filePath: path))
        }
        return try LibraryStore.defaultStore()
    }

    private static func optionValue(_ option: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: option) else {
            return nil
        }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else {
            return nil
        }
        return arguments[valueIndex]
    }

    private static func printHelp() {
        print("""
        wwbctl scan <folder> [--out <index.json>]
        wwbctl import <folder> [--library <folder>]
        wwbctl import-video <video-file> [--library <folder>]
        wwbctl remove <asset-id> [--library <folder>]
        wwbctl convert <input-video> --out <output.mp4>
        wwbctl doctor
        """)
    }
}

private enum CLIError: Error, LocalizedError {
    case unknownCommand(String)
    case missingPath
    case missingAssetId
    case invalidConvertUsage

    var errorDescription: String? {
        switch self {
        case .unknownCommand(let command):
            return "unknown command: \(command)"
        case .missingPath:
            return "missing folder path"
        case .missingAssetId:
            return "missing asset id"
        case .invalidConvertUsage:
            return "usage: wwbctl convert <input-video> --out <output.mp4>"
        }
    }
}

private extension JSONEncoder {
    static var cli: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
