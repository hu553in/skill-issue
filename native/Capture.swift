@preconcurrency import AVFoundation
import AppKit
import OSLog
import ScreenCaptureKit

private let captureLog = Logger(
    subsystem: "com.github.hu553in.skill-issue", category: "Capture")

@MainActor
final class Capture {
    private var stream: SCStream?
    private var sink: AudioSink?
    private var filter: SCContentFilter?
    private var display: SCDisplay?
    private let speech = SpeechEngine()
    private var origin = 0.0
    var seconds: Double {
        max(0, CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) - origin)
    }

    func prepare(progress: @escaping @Sendable (String) -> Void) async throws {
        try await speech.prepare(progress: progress)
    }
    func start(
        microphone: String,
        failed: @escaping @MainActor @Sendable () -> Void
    ) async throws {
        guard await AVCaptureDevice.requestAccess(for: .audio),
            CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
        else { throw AppFailure.failed }
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        guard
            let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                ?? content.displays.first
        else { throw AppFailure.failed }
        self.display = display
        let own = content.applications.filter {
            $0.processID == ProcessInfo.processInfo.processIdentifier
        }
        let filter = SCContentFilter(
            display: display, excludingApplications: own, exceptingWindows: [])
        self.filter = filter
        origin = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        try await speech.start(failed: { Task { @MainActor in failed() } })
        do {
            let sink = AudioSink(speech: speech, origin: origin, failed: failed)
            self.sink = sink
            let config = SCStreamConfiguration()
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 600)
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 48000
            config.channelCount = 1
            config.captureMicrophone = true
            if !microphone.isEmpty { config.microphoneCaptureDeviceID = microphone }
            let stream = SCStream(filter: filter, configuration: config, delegate: sink)
            self.stream = stream
            try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: sink.queue)
            try stream.addStreamOutput(sink, type: .microphone, sampleHandlerQueue: sink.queue)
            try await stream.startCapture()
            captureLog.notice("Live capture started")
        } catch {
            await stop()
            throw error
        }
    }
    func freeze() -> AsyncThrowingStream<(Double, [TranscriptSegment]), Error> {
        let origin = origin
        return AsyncThrowingStream { continuation in
            guard let sink else {
                continuation.finish(throwing: AppFailure.failed)
                return
            }
            // Enqueue before returning so rapid Answer presses keep their order.
            sink.queue.async {
                // The time and recognition cut share the same capture-queue
                // boundary. A delivered buffer belongs wholly to this batch.
                let now = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) - origin
                let cutoff = max(now, sink.deliveredThrough)
                sink.speech.freeze { result in
                    switch result {
                    case .success(let transcript):
                        continuation.yield((cutoff, transcript))
                        continuation.finish()
                    case .failure(let error): continuation.finish(throwing: error)
                    }
                }
            }
        }
    }
    func screenshot() async throws -> (Data, Double) {
        guard let filter, let display else { throw AppFailure.failed }
        let config = SCStreamConfiguration()
        let scale = min(1, 1600.0 / Double(display.width))
        config.width = Int(Double(display.width) * scale)
        config.height = Int(Double(display.height) * scale)
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config)
        guard
            let data = NSBitmapImageRep(cgImage: image).representation(
                using: .jpeg, properties: [.compressionFactor: 0.8])
        else { throw AppFailure.failed }
        return (data, seconds)
    }
    func stop() async {
        if let stream { try? await stream.stopCapture() }
        stream = nil
        if let sink {
            await withCheckedContinuation { continuation in
                sink.queue.async { continuation.resume() }
            }
        }
        await speech.stop()
        sink = nil
        filter = nil
        display = nil
    }
}

private final class AudioSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.github.hu553in.skill-issue.audio", qos: .userInitiated)
    let speech: SpeechEngine
    private(set) var deliveredThrough = 0.0
    private let origin: Double
    private let failed: @MainActor @Sendable () -> Void
    private var converters: [AudioSource: AVAudioConverter] = [:]
    private let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    init(speech: SpeechEngine, origin: Double, failed: @escaping @MainActor @Sendable () -> Void) {
        self.speech = speech
        self.origin = origin
        self.failed = failed
    }
    func stream(
        _ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio || type == .microphone else { return }
        do {
            guard CMSampleBufferIsValid(sample),
                let description = CMSampleBufferGetFormatDescription(sample),
                let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description),
                let inputFormat = AVAudioFormat(streamDescription: basic)
            else { return }
            let frames = CMSampleBufferGetNumSamples(sample)
            guard frames > 0,
                let input = AVAudioPCMBuffer(
                    pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frames))
            else { return }
            input.frameLength = AVAudioFrameCount(frames)
            guard
                CMSampleBufferCopyPCMDataIntoAudioBufferList(
                    sample, at: 0, frameCount: Int32(frames), into: input.mutableAudioBufferList)
                    == noErr
            else { throw AppFailure.failed }
            let source: AudioSource = type == .audio ? .computer : .microphone
            if converters[source]?.inputFormat != inputFormat {
                converters[source] = AVAudioConverter(from: inputFormat, to: format)
            }
            guard let converter = converters[source],
                let output = AVAudioPCMBuffer(
                    pcmFormat: format,
                    frameCapacity: AVAudioFrameCount(
                        ceil(Double(frames) * format.sampleRate / inputFormat.sampleRate)) + 64)
            else { throw AppFailure.failed }
            var supplied = false
            var error: NSError?
            let result = converter.convert(to: output, error: &error) { _, state in
                if supplied {
                    state.pointee = .noDataNow
                    return nil
                }
                supplied = true
                state.pointee = .haveData
                return input
            }
            guard result != .error, error == nil else { throw AppFailure.failed }
            let timestamp =
                CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)) - origin
            guard timestamp.isFinite, let samples = output.floatChannelData?[0],
                output.frameLength > 0
            else { return }
            let start = max(0, timestamp)
            deliveredThrough = max(
                deliveredThrough, start + Double(output.frameLength) / format.sampleRate)
            speech.receive(
                Array(UnsafeBufferPointer(start: samples, count: Int(output.frameLength))),
                source: source, seconds: start)
        } catch {
            captureLog.error("Audio conversion failed")
            Task { @MainActor in failed() }
        }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in failed() }
    }
}
