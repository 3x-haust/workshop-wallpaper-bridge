import Darwin
import Foundation
import JavaScriptCore

/// Never evaluate creator code on the app's main actor. This class is used by
/// the worker entry point and by tests containing only trusted fixture scripts.
final class SceneScriptWorkerRuntime {
    private let context: JSContext
    private let handler: JSValue
    private let textMetrics = SceneTextMetrics()
    static let maximumMessageBytes = 1_048_576

    init() throws {
        guard let context = JSContext(),
              let url = Bundle.module.url(forResource: "SceneScriptRuntime", withExtension: "js") else {
            throw SceneScriptProcessError.unavailable
        }
        context.exceptionHandler = { _, _ in }
        let metrics = textMetrics
        let measure: @convention(block) (Int, String) -> [Double]? = { id, text in metrics.measure(id: id, text: text) }
        context.setObject(measure, forKeyedSubscript: "__wwbMeasureText" as NSString)
        let source = try String(contentsOf: url, encoding: .utf8)
        guard let handler = context.evaluateScript(source), !handler.isUndefined, context.exception == nil else {
            throw SceneScriptProcessError.invalidResponse
        }
        self.context = context
        self.handler = handler
    }

    func respond(to data: Data) throws -> Data {
        guard data.count <= Self.maximumMessageBytes,
              let input = String(data: data, encoding: .utf8) else { throw SceneScriptProcessError.invalidResponse }
        context.exception = nil
        if let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let configuration = request["configure"] as? [String: Any] { textMetrics.configure(configuration) }
        guard let result = handler.call(withArguments: [input]), context.exception == nil,
              let output = result.toString()?.data(using: .utf8), output.count <= Self.maximumMessageBytes else {
            throw SceneScriptProcessError.invalidResponse
        }
        return output
    }

    static func run() {
        // An independent watchdog still runs if JavaScript is allocating or looping.
        let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        watchdog.schedule(deadline: .now(), repeating: .milliseconds(50))
        watchdog.setEventHandler {
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                }
            }
            if result == KERN_SUCCESS, info.resident_size > 256 * 1024 * 1024 { _exit(70) }
        }
        watchdog.resume()
        defer { watchdog.cancel() }
        do {
            let runtime = try SceneScriptWorkerRuntime()
            var pending = Data()
            while true {
                let bytes = FileHandle.standardInput.availableData
                guard !bytes.isEmpty else { return }
                pending.append(bytes)
                guard pending.count <= maximumMessageBytes + 1 else { return }
                while let newline = pending.firstIndex(of: 10) {
                    let request = Data(pending[..<newline])
                    pending.removeSubrange(...newline)
                    let response = try autoreleasepool { try runtime.respond(to: request) }
                    try FileHandle.standardOutput.write(contentsOf: response + Data([10]))
                }
            }
        } catch { _exit(65) }
    }
}

enum SceneScriptProcessError: Error, LocalizedError {
    case unavailable, stopped, invalidResponse
    var errorDescription: String? {
        switch self {
        case .unavailable: "SceneScript worker is unavailable."
        case .stopped: "SceneScript worker stopped or exceeded its execution limit."
        case .invalidResponse: "SceneScript worker returned invalid or excessive data."
        }
    }
}

/// One serial pipe exchange per scene. close() can interrupt a blocked read from
/// any thread. The lock protects lifetime; the queue owns all pipe I/O.
final class SceneScriptProcess: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.3xhaust.scene-script-worker", qos: .userInitiated)
    private let lock = NSLock()
    private var process: Process?
    private var closed = false
    private var requestID = 0
    private var activeRequest: Int?
    private var input: FileHandle?
    private var output: FileHandle?

    static func executableURL(in appBundle: Bundle = .main) -> URL? {
        if let url = appBundle.executableURL,
           ["WorkshopWallpaperBridge", "Workshop Wallpaper Bridge"].contains(url.lastPathComponent) { return url }
        // XCTest executes in a bundle beside the SwiftPM executable.
        let executable = Bundle.module.bundleURL
        var directory = executable.deletingLastPathComponent()
        for _ in 0..<5 {
            let candidate = directory.appending(path: "WorkshopWallpaperBridge")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            directory.deleteLastPathComponent()
        }
        return nil
    }

    func exchange(_ data: Data, timeout: TimeInterval = 0.25) async throws -> Data {
        guard data.count <= SceneScriptWorkerRuntime.maximumMessageBytes else { throw SceneScriptProcessError.invalidResponse }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do { continuation.resume(returning: try exchangeBlocking(data, timeout: timeout)) }
                catch { close(); continuation.resume(throwing: error) }
            }
        }
    }

    private func exchangeBlocking(_ data: Data, timeout: TimeInterval) throws -> Data {
        lock.lock()
        guard !closed else { lock.unlock(); throw SceneScriptProcessError.stopped }
        if process == nil {
            guard let url = Self.executableURL() else { lock.unlock(); throw SceneScriptProcessError.unavailable }
            let child = Process(), stdinPipe = Pipe(), stdoutPipe = Pipe()
            child.executableURL = url
            child.arguments = ["--scene-script-worker"]
            child.standardInput = stdinPipe
            child.standardOutput = stdoutPipe
            child.standardError = FileHandle.nullDevice
            // The worker does not need the parent's credentials or environment overrides.
            child.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
            do { try child.run() } catch { lock.unlock(); throw error }
            process = child
            input = stdinPipe.fileHandleForWriting
            output = stdoutPipe.fileHandleForReading
        }
        requestID += 1
        let id = requestID
        activeRequest = id
        let input = self.input!, output = self.output!
        lock.unlock()
        let deadline = DispatchWorkItem { [weak self] in self?.expire(request: id) }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
        defer {
            deadline.cancel()
            lock.lock(); activeRequest = nil; lock.unlock()
        }
        try input.write(contentsOf: data + Data([10]))
        var response = Data()
        while response.count <= SceneScriptWorkerRuntime.maximumMessageBytes {
            let bytes = output.availableData
            guard !bytes.isEmpty else { throw SceneScriptProcessError.stopped }
            response.append(bytes)
            if response.last == 10 {
                response.removeLast()
                guard response.count <= SceneScriptWorkerRuntime.maximumMessageBytes,
                      !response.contains(10) else { throw SceneScriptProcessError.invalidResponse }
                return response
            }
        }
        throw SceneScriptProcessError.invalidResponse
    }

    private func expire(request: Int) {
        lock.lock(); defer { lock.unlock() }
        guard activeRequest == request else { return }
        terminateLocked()
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        terminateLocked()
    }

    private func terminateLocked() {
        closed = true
        if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    deinit {
        close()
        try? input?.close()
        try? output?.close()
    }
}
