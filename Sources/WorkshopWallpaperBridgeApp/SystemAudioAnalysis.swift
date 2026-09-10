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
final class SystemAudioAnalysis: ObservableObject {
    static let shared = SystemAudioAnalysis()
    @Published private(set) var status = ""
    private(set) var spectrum = WallpaperAudioSpectrum()
    private var lastSample = Date.distantPast
    private var desired = false
    private var consumers = Set<UUID>()
    private var generation = 0
    private var transition: Task<Void, Never>?
    private var stream: SCStream?
    private var output: WallpaperAudioOutput?
    private let queue = DispatchQueue(label: "dev.3xhaust.wallpaper-audio")

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
        consumers.remove(id)
        if consumers.isEmpty { reconcile() }
    }

    func setEnabled(_ enabled: Bool) {
        desired = enabled
        reconcile()
    }

    private func reconcile() {
        generation += 1
        let token = generation, previous = transition
        spectrum = WallpaperAudioSpectrum()
        status = ""
        transition = Task { [weak self] in
            await previous?.value
            guard let self, self.generation == token else { return }
            if let stream = self.stream { try? await stream.stopCapture() }
            self.stream = nil
            self.output = nil
            guard self.desired, !self.consumers.isEmpty, self.generation == token else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard self.generation == token, self.desired else { return }
                guard let display = content.displays.first else { throw SceneScriptProcessError.unavailable }
                let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 2
                config.height = 2
                config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                config.sampleRate = 48_000
                config.channelCount = 2
                let output = WallpaperAudioOutput(receive: { [weak self] spectrum in
                    Task { @MainActor in
                        guard let self, self.generation == token, self.desired else { return }
                        self.spectrum = spectrum
                        self.lastSample = Date()
                    }
                }, stopped: { [weak self] message in
                    Task { @MainActor in
                        guard let self, self.generation == token else { return }
                        self.spectrum = WallpaperAudioSpectrum()
                        self.lastSample = .distantPast
                        self.status = message
                    }
                })
                let stream = SCStream(filter: filter, configuration: config, delegate: output)
                try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: self.queue)
                self.stream = stream
                self.output = output
                try await stream.startCapture()
                if self.generation != token || !self.desired { try? await stream.stopCapture() }
            } catch {
                if self.generation == token {
                    self.status = error.localizedDescription
                    self.spectrum = WallpaperAudioSpectrum()
                }
            }
        }
    }
}
