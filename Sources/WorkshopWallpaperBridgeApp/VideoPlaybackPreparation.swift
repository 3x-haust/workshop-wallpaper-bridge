import AVFoundation
import CryptoKit
import Darwin
import Foundation
import WorkshopWallpaperCore

/// Only repairs the HEVC `hev1` sample entry rejected by AVFoundation. Encoded
/// video and audio packets are copied, never transcoded or written to the source.
@MainActor
final class VideoPlaybackPreparation {
    private static let shared = VideoPlaybackPreparation(cacheDirectory: cacheDirectoryURL())

    static func cacheDirectoryURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appending(path: "WorkshopWallpaperBridge/VideoPlaybackCache/v1")
    }

    static func prepare(url: URL, assetID: String?) async throws -> URL {
        try await shared.prepare(url: url, assetID: assetID)
    }

    /// Remains true after cancellation until the subprocess exits and temporary
    /// files have been removed. Library deletion must check this on the main actor.
    static func isPreparing(assetID: String) -> Bool {
        shared.isPreparing(assetID: assetID)
    }

    private struct Fingerprint: Codable, Equatable {
        let sourceURL: String
        let modified: Date
        let size: UInt64

        init(url: URL) throws {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let modified = attributes[.modificationDate] as? Date,
                  let size = attributes[.size] as? NSNumber else {
                throw PreparationError("The video source is not a regular file.")
            }
            sourceURL = url.absoluteString
            self.modified = modified
            self.size = size.uint64Value
        }
    }

    @MainActor
    private final class Pending {
        let source: URL
        var task: Task<URL, Error>!
        var waiters: Set<UUID> = []
        init(source: URL) { self.source = source }
    }

    private let cacheDirectory: URL
    private let ffmpegPath: String?
    private var pending: [String: Pending] = [:]

    init(cacheDirectory: URL, ffmpegPath: String? = VideoConverter().ffmpegPath()) {
        self.cacheDirectory = cacheDirectory.standardizedFileURL
        self.ffmpegPath = ffmpegPath
    }

    func isPreparing(assetID: String) -> Bool { pending[assetID] != nil }

    func prepare(url: URL, assetID: String?) async throws -> URL {
        try Task.checkCancellation()
        guard url.isFileURL else { throw PreparationError("Video playback requires a local file.") }
        let source = url.standardizedFileURL.resolvingSymlinksInPath()
        let key: String
        if let assetID {
            guard !assetID.isEmpty, assetID.utf8.count <= 128,
                  assetID.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                      || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else {
                throw PreparationError("The video cache asset ID is invalid.")
            }
            key = assetID
        } else {
            key = "anonymous-" + SHA256.hash(data: Data(source.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        let operation: Pending
        if let existing = pending[key] {
            guard existing.source == source else {
                throw PreparationError("Another video source is being prepared for this asset.")
            }
            operation = existing
        } else {
            operation = Pending(source: source)
            pending[key] = operation
            operation.task = Task {
                defer { pending[key] = nil }
                return try await prepareSource(source, key: key)
            }
        }
        let waiter = UUID()
        operation.waiters.insert(waiter)
        defer { release(waiter, from: operation) }
        return try await withTaskCancellationHandler {
            let result = try await operation.task.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            Task { @MainActor in self.release(waiter, from: operation) }
        }
    }

    private func release(_ waiter: UUID, from operation: Pending) {
        guard operation.waiters.remove(waiter) != nil else { return }
        if operation.waiters.isEmpty { operation.task.cancel() }
    }

    private func prepareSource(_ source: URL, key: String) async throws -> URL {
        try Task.checkCancellation()
        let fingerprint = try Fingerprint(url: source)
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw PreparationError("The selected file has no video track.")
        }
        let formats = try await track.load(.formatDescriptions)
        try Task.checkCancellation()
        // FourCC 'hev1', obtained from the video format description, not bytes
        // searched in an untrusted media file.
        guard formats.contains(where: { CMFormatDescriptionGetMediaSubType($0) == 0x68657631 }) else { return source }

        try validateCachePath(cacheDirectory)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let output = cacheDirectory.appending(path: "\(key).mp4")
        let metadata = cacheDirectory.appending(path: "\(key).json")
        try validateCachePath(output)
        try validateCachePath(metadata)
        if let data = try? Data(contentsOf: metadata),
           let cached = try? JSONDecoder().decode(Fingerprint.self, from: data),
           cached == fingerprint,
           let attributes = try? FileManager.default.attributesOfItem(atPath: output.path),
           attributes[.type] as? FileAttributeType == .typeRegular,
           (attributes[.size] as? NSNumber)?.uint64Value ?? 0 > 0 {
            return output
        }
        guard let ffmpegPath else { throw ConversionError.ffmpegNotFound }
        let temporary = cacheDirectory.appending(path: ".\(key).\(UUID()).mp4")
        let temporaryMetadata = temporary.deletingPathExtension().appendingPathExtension("json")
        defer {
            try? FileManager.default.removeItem(at: temporary)
            try? FileManager.default.removeItem(at: temporaryMetadata)
        }
        let process = RemuxProcess(executable: ffmpegPath, source: source, output: temporary)
        try await withTaskCancellationHandler {
            try await Task.detached { try process.run() }.value
        } onCancel: {
            process.cancel()
        }
        try Task.checkCancellation()
        try await Self.verifyFirstFrame(url: temporary)
        try Task.checkCancellation()
        guard try Fingerprint(url: source) == fingerprint else {
            throw PreparationError("The video source changed while its playback copy was being prepared.")
        }
        try JSONEncoder().encode(fingerprint).write(to: temporaryMetadata, options: .withoutOverwriting)
        try validateCachePath(output)
        try validateCachePath(metadata)
        try publish(temporary, to: output)
        try publish(temporaryMetadata, to: metadata)
        return output
    }

    /// A ready player item alone does not establish that the decoder produces
    /// frames (notably for hev1). No image is persisted or displayed here.
    static func verifyFirstFrame(url: URL) async throws {
        try Task.checkCancellation()
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.maximumSize = CGSize(width: 32, height: 32)
        _ = try await generator.image(at: .zero)
        try Task.checkCancellation()
    }

    private func validateCachePath(_ url: URL) throws {
        var component = url.standardizedFileURL
        while component.path != "/" {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: component.path) {
                // Foundation can standardize /private/var back to /var. Allow
                // only this root-owned macOS alias, never links inside the cache.
                if component.path == "/var",
                   attributes[.type] as? FileAttributeType == .typeSymbolicLink,
                   let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: component.path),
                   ["private/var", "/private/var"].contains(destination) {
                    component.deleteLastPathComponent()
                    continue
                }
                guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else {
                    throw PreparationError("The video cache must not contain symbolic links.")
                }
                let expectedType: FileAttributeType = component != url || url == cacheDirectory ? .typeDirectory : .typeRegular
                guard attributes[.type] as? FileAttributeType == expectedType else {
                    throw PreparationError("The video cache contains an unexpected file type.")
                }
            }
            component.deleteLastPathComponent()
        }
    }

    private func publish(_ temporary: URL, to destination: URL) throws {
        guard rename(temporary.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private struct PreparationError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

/// Protects launch against cancellation; completion always waits for the actual
/// child exit before the caller clears its preparation/deletion gate.
private final class RemuxProcess: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private var cancelled = false

    init(executable: String, source: URL, output: URL) {
        process.executableURL = URL(filePath: executable)
        process.arguments = ["-nostdin", "-v", "error", "-i", source.path, "-map", "0:v:0", "-map", "0:a?",
                             "-c", "copy", "-tag:v", "hvc1", "-n", output.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
    }

    func run() throws {
        try lock.withLock {
            if cancelled { throw CancellationError() }
            try process.run()
        }
        process.waitUntilExit()
        try lock.withLock {
            if cancelled { throw CancellationError() }
            guard process.terminationStatus == 0 else { throw ConversionError.ffmpegFailed(process.terminationStatus) }
        }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            if process.isRunning { process.terminate() }
        }
    }
}
