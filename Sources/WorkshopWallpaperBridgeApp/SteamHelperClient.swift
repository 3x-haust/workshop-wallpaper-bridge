import Foundation
import Darwin

struct WorkshopItem: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let description: String
    let previewURL: String?
    let kind: String?
    let size: UInt64?
}

struct SteamCommand: Encodable, Sendable {
    let id: String
    let command: String
    var username: String?
    var password: String?
    var code: String?
    var query: String?
    var page: Int?
    var itemID: String?
    var directory: String?
}

struct SteamEvent: Decodable, Sendable {
    let id: String
    let type: String
    var url: String?
    var prompt: String?
    var account: String?
    var items: [WorkshopItem]?
    var item: WorkshopItem?
    var total: Int?
    var page: Int?
    var pageSize: Int?
    var completed: UInt64?
    var itemID: String?
    var code: String?
}

@MainActor
protocol SteamHelperTransport: AnyObject {
    var onEvent: ((SteamEvent) -> Void)? { get set }
    var onExit: (() -> Void)? { get set }
    func send(_ command: SteamCommand) throws
    func stop() async
}

enum SteamBridgeError: Error {
    case unavailable, protocolViolation, busy, invalidItem, unsafePath, noProject
}

/// Only framed, typed IPC reaches the app. Raw helper diagnostics are discarded.
@MainActor
final class SteamHelperClient: SteamHelperTransport {
    var onEvent: ((SteamEvent) -> Void)?
    var onExit: (() -> Void)?
    private let executable: URL
    private let authenticationDirectory: URL
    private var process: Process?
    private var input: FileHandle?
    private var reader: Task<Void, Never>?
    private var buffer = Data()

    init(executable: URL? = nil, authenticationDirectory: URL) {
        self.authenticationDirectory = authenticationDirectory
        self.executable = executable ?? Self.bundledExecutable
    }

    static var bundledExecutable: URL {
        if let resources = Bundle.main.resourceURL {
            let bundled = resources.appending(path: "Steam/wwb-steam-helper")
            if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        }
        return URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: ".build/steam-helper/wwb-steam-helper")
    }

    func send(_ command: SteamCommand) throws {
        if process == nil { try start() }
        guard let input, process?.isRunning == true else { throw SteamBridgeError.unavailable }
        var data = try JSONEncoder().encode(command)
        data.append(0x0a)
        try input.write(contentsOf: data)
    }

    private func start() throws {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw SteamBridgeError.unavailable
        }
        let child = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        child.executableURL = executable
        child.arguments = ["--data-directory", authenticationDirectory.path]
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        try child.run()
        process = child
        input = stdin.fileHandleForWriting
        buffer.removeAll()
        let output = stdout.fileHandleForReading
        reader = Task.detached { [weak self] in
            while true {
                let data = output.availableData
                if data.isEmpty { break }
                await self?.receive(data)
            }
            child.waitUntilExit()
            try? output.close()
            await self?.didExit(child)
        }
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        // Bound both malformed frames and unexpectedly large service responses.
        guard buffer.count <= 4 * 1024 * 1024 else {
            buffer.removeAll()
            Task { await stop() }
            return
        }
        while let newline = buffer.firstIndex(of: 0x0a) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            guard let event = try? JSONDecoder().decode(SteamEvent.self, from: line) else {
                Task { await stop() }
                return
            }
            onEvent?(event)
        }
    }

    private func didExit(_ child: Process) {
        guard process === child else { return }
        process = nil
        try? input?.close()
        input = nil
        buffer.removeAll()
        onExit?()
    }

    func stop() async {
        guard let child = process else { return }
        try? input?.close()
        input = nil
        if child.isRunning { child.terminate() }
        let escalation = Task {
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled, child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
        await reader?.value
        escalation.cancel()
    }
}

struct SteamAuthenticationStorage {
    let directory: URL

    var hasSavedSession: Bool {
        (try? checkedCredentialURL()).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    var hasStoredAuthentication: Bool {
        ["credentials.json", "credentials.json.tmp"].contains { name in
            (try? checkedCredentialURL(name)).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        }
    }

    func deleteSavedSession() throws {
        let files = try ["credentials.json", "credentials.json.tmp"].map { try checkedCredentialURL($0) }
        for url in files {
            if unlink(url.path) != 0, errno != ENOENT {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    private func checkedCredentialURL(_ name: String = "credentials.json") throws -> URL {
        let file = directory.appending(path: name)
        var cursor = file
        while cursor.path != "/" {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: cursor.path) {
                let type = attributes[.type] as? FileAttributeType
                if type == .typeSymbolicLink || (cursor == file && type != .typeRegular) {
                    throw SteamBridgeError.unsafePath
                }
            }
            cursor.deleteLastPathComponent()
        }
        return file
    }
}
