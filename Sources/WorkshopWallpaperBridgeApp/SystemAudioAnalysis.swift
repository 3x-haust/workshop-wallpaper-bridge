import Accelerate
import AppKit
import AVFoundation
// Older SDKs lack Sendable annotations on the newly returned content snapshot.
// Stream configuration stays on the main actor; PCM analysis has its own queue.
@preconcurrency import ScreenCaptureKit

struct WallpaperAudioSpectrum: Sendable {
    var left = Array(repeating: Float(0), count: 64)
    var right = Array(repeating: Float(0), count: 64)
}

/// The FFT is confined to the capture output queue. Band layout and gain are a
/// compatibility approximation; they have not been calibrated to Windows.
final class WallpaperSpectrumAnalyzer {
    static let frameCount = 2048
    private let transform = vDSP.DFT(count: frameCount, direction: .forward, transformType: .complexComplex, ofType: Float.self)!
    private var leftSamples: [Float] = []
    private var rightSamples: [Float] = []
    private let window: [Float] = (0..<frameCount).map { Float(0.5 - 0.5 * cos(2 * .pi * Double($0) / Double(frameCount - 1))) }

    func append(left: [Float], right: [Float], sampleRate: Double) -> WallpaperAudioSpectrum? {
        guard sampleRate.isFinite, sampleRate > 0, left.count == right.count else { return nil }
        leftSamples.append(contentsOf: left.suffix(Self.frameCount))
        rightSamples.append(contentsOf: right.suffix(Self.frameCount))
        guard leftSamples.count >= Self.frameCount else { return nil }
        leftSamples = Array(leftSamples.suffix(Self.frameCount))
        rightSamples = Array(rightSamples.suffix(Self.frameCount))
        let result = WallpaperAudioSpectrum(left: bands(leftSamples, sampleRate: sampleRate), right: bands(rightSamples, sampleRate: sampleRate))
        leftSamples.removeAll(keepingCapacity: true)
        rightSamples.removeAll(keepingCapacity: true)
        return result
    }

    private func bands(_ samples: [Float], sampleRate: Double) -> [Float] {
        let real = zip(samples, window).map { $0.isFinite ? $0 * $1 : 0 }
        let fft = transform.transform(inputReal: real, inputImaginary: Array(repeating: 0, count: Self.frameCount))
        let high = min(20_000, sampleRate / 2)
        return (0..<64).map { band in
            let lowFrequency = 20 * pow(high / 20, Double(band) / 64)
            let highFrequency = 20 * pow(high / 20, Double(band + 1) / 64)
            let first = max(1, min(Self.frameCount / 2 - 1, Int(lowFrequency * Double(Self.frameCount) / sampleRate)))
            let last = max(first, min(Self.frameCount / 2 - 1, Int(highFrequency * Double(Self.frameCount) / sampleRate)))
            var peak: Float = 0
            for i in first...last { peak = max(peak, hypotf(fft.real[i], fft.imaginary[i])) }
            return min(1, peak * 4 / Float(Self.frameCount))
        }
    }
}

private final class WallpaperAudioOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let analyzer = WallpaperSpectrumAnalyzer()
    let receive: @Sendable (WallpaperAudioSpectrum) -> Void
    let stopped: @Sendable (String) -> Void
    init(receive: @escaping @Sendable (WallpaperAudioSpectrum) -> Void, stopped: @escaping @Sendable (String) -> Void) {
        self.receive = receive
        self.stopped = stopped
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { stopped(error.localizedDescription) }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let description = sampleBuffer.formatDescription,
              let formatDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              formatDescription.pointee.mChannelsPerFrame > 0, formatDescription.pointee.mChannelsPerFrame <= 2,
              let format = AVAudioFormat(streamDescription: formatDescription), format.commonFormat == .pcmFormatFloat32 else { return }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0, frames <= 8192,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList) == noErr,
              let channels = buffer.floatChannelData else { return }
        let stride = buffer.stride
        let left = (0..<frames).map { channels[0][$0 * stride] }
        let right: [Float]
        if format.channelCount == 1 { right = left }
        else if format.isInterleaved { right = (0..<frames).map { channels[0][$0 * stride + 1] } }
        else { right = (0..<frames).map { channels[1][$0 * stride] } }
        if let spectrum = analyzer.append(left: left, right: right, sampleRate: format.sampleRate) { receive(spectrum) }
    }
}

@MainActor
protocol SystemAudioCapturing: AnyObject {
    func stop() async
}

@MainActor
private final class SystemAudioCapture: SystemAudioCapturing {
    let stream: SCStream
    let output: WallpaperAudioOutput
    init(stream: SCStream, output: WallpaperAudioOutput) { self.stream = stream; self.output = output }
    func stop() async { try? await stream.stopCapture() }
}

@MainActor
final class SystemAudioAnalysis: ObservableObject {
    typealias StartCapture = @MainActor (
        @escaping @Sendable (WallpaperAudioSpectrum) -> Void,
        @escaping @Sendable (String) -> Void
    ) async throws -> any SystemAudioCapturing

    static let shared = SystemAudioAnalysis()
    @Published private(set) var status = ""
    @Published private(set) var needsPermission = false
    private(set) var spectrum = WallpaperAudioSpectrum()
    private var lastSample = Date.distantPast
    private var desired = false
    private var granted: Bool
    private var requestedPermission = false
    private var requestingPermission = false
    private var captureFailed = false
    private var consumers = Set<UUID>()
    private var generation = 0
    private var transition: Task<Void, Never>?
    private var capture: (any SystemAudioCapturing)?
    private var permissionTimer: Timer?
    private let permissionCheck: @MainActor () -> Bool
    private let permissionRequest: @MainActor () -> Bool
    private let openSettings: @MainActor () -> Void
    private let automaticallyRefreshPermission: Bool
    private let startCapture: StartCapture

    init(permissionCheck: @escaping @MainActor () -> Bool = { CGPreflightScreenCaptureAccess() },
         permissionRequest: @escaping @MainActor () -> Bool = { CGRequestScreenCaptureAccess() },
         openSettings: @escaping @MainActor () -> Void = {
             if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                 NSWorkspace.shared.open(url)
             }
         }, automaticallyRefreshPermission: Bool = true,
         startCapture: @escaping StartCapture = SystemAudioAnalysis.startSystemCapture) {
        self.permissionCheck = permissionCheck
        self.permissionRequest = permissionRequest
        self.openSettings = openSettings
        self.automaticallyRefreshPermission = automaticallyRefreshPermission
        self.startCapture = startCapture
        granted = permissionCheck()
    }

    var currentSpectrum: WallpaperAudioSpectrum {
        Date().timeIntervalSince(lastSample) < 0.3 ? spectrum : WallpaperAudioSpectrum()
    }

    func acquire() -> UUID {
        let id = UUID(), wasEmpty = consumers.isEmpty
        consumers.insert(id)
        if wasEmpty { reconcile() }
        return id
    }

    func release(_ id: UUID) {
        guard consumers.remove(id) != nil else { return }
        if consumers.isEmpty { reconcile() }
    }

    func setEnabled(_ enabled: Bool) {
        guard desired != enabled else { refreshPermission(); return }
        desired = enabled
        captureFailed = false
        permissionTimer?.invalidate(); permissionTimer = nil
        if enabled && automaticallyRefreshPermission {
            // Preflight never prompts. Observe changes made in System Settings,
            // including while this menu-bar app has no active settings window.
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                Task { @MainActor in self.refreshPermission() }
            }
        }
        granted = permissionCheck()
        reconcile()
    }

    func refreshPermission() {
        let next = permissionCheck()
        needsPermission = desired && !next
        guard next != granted else { return }
        granted = next
        captureFailed = false
        reconcile()
    }

    /// Called only from the user's authorization button, never from playback,
    /// activation, permission polling or a restored preference.
    func authorize() {
        guard desired, !requestingPermission else { return }
        refreshPermission()
        guard !granted else { return }
        requestingPermission = true
        defer { requestingPermission = false }
        if !requestedPermission {
            requestedPermission = true
            _ = permissionRequest()
        }
        refreshPermission()
        if !granted { openSettings() }
    }

    func waitForTransition() async { await transition?.value }

    func retryCapture() {
        guard desired else { return }
        refreshPermission()
        guard granted, captureFailed else { return }
        captureFailed = false
        reconcile()
    }

    private func reconcile() {
        generation += 1
        let token = generation, previous = transition
        spectrum = WallpaperAudioSpectrum(); lastSample = .distantPast
        needsPermission = desired && !granted
        if !captureFailed || !desired || needsPermission { status = "" }
        transition = Task { [weak self] in
            await previous?.value
            guard let self, self.generation == token else { return }
            if let capture = self.capture { await capture.stop() }
            self.capture = nil
            guard self.desired, !self.consumers.isEmpty, self.granted, !self.captureFailed, self.generation == token else { return }
            // Recheck immediately before invoking an API that could prompt.
            guard self.permissionCheck() else { self.refreshPermission(); return }
            do {
                let capture = try await self.startCapture({ [weak self] spectrum in
                    Task { @MainActor in
                        guard let self, self.generation == token, self.desired, self.granted, !self.captureFailed else { return }
                        self.spectrum = spectrum
                        self.lastSample = Date()
                    }
                }, { [weak self] message in
                    Task { @MainActor in
                        guard let self, self.generation == token else { return }
                        self.spectrum = WallpaperAudioSpectrum()
                        self.lastSample = .distantPast
                        self.captureFailed = true
                        self.refreshPermission()
                        if !self.needsPermission { self.status = message }
                    }
                })
                guard self.generation == token, self.desired, self.granted, !self.captureFailed else { await capture.stop(); return }
                self.capture = capture
            } catch {
                guard self.generation == token else { return }
                self.captureFailed = true
                self.refreshPermission()
                if !self.needsPermission {
                    let failure = error as NSError
                    self.status = failure.domain == SCStreamErrorDomain && failure.code == -3801
                        ? "settings.audioReactive.restart" : error.localizedDescription
                }
                self.spectrum = WallpaperAudioSpectrum()
            }
        }
    }

    private static func startSystemCapture(
        receive: @escaping @Sendable (WallpaperAudioSpectrum) -> Void,
        stopped: @escaping @Sendable (String) -> Void
    ) async throws -> any SystemAudioCapturing {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw SceneScriptProcessError.unavailable }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = 2; config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.capturesAudio = true; config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000; config.channelCount = 2
        let output = WallpaperAudioOutput(receive: receive, stopped: stopped)
        let stream = SCStream(filter: filter, configuration: config, delegate: output)
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: DispatchQueue(label: "dev.3xhaust.wallpaper-audio"))
        do { try await stream.startCapture() }
        catch { try? await stream.stopCapture(); throw error }
        return SystemAudioCapture(stream: stream, output: output)
    }
}
