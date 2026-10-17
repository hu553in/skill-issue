import AudioCommon
import CryptoKit
import Foundation
@preconcurrency import NemotronStreamingASR

// All inference and session mutation runs on queue. Preparation finishes before
// capture starts; one loaded model serves the two independent source sessions.
final class SpeechEngine: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "com.github.hu553in.skill-issue.speech", qos: .userInitiated)
    private var model: NemotronStreamingASRModel?
    private var tracks: [AudioSource: Track] = [:]
    private var epoch = 0
    private var active = false
    private var failed: (@Sendable () -> Void)?
    private let pendingLock = NSLock()
    private var pendingFrames = 0

    private final class Track {
        let session: any StreamingRecognitionSession
        var frames = 0
        var spans: [(audio: Double, capture: Double)] = []
        var update: StreamingRecognitionUpdate?
        init(_ session: any StreamingRecognitionSession) { self.session = session }
        func time(_ seconds: Double) -> Double {
            let span = spans.last(where: { $0.audio <= seconds }) ?? spans.first ?? (0, 0)
            return span.capture + seconds - span.audio
        }
    }
    private struct Manifest: Decodable {
        struct File: Decodable {
            var bytes: Int
            var sha256: String
        }
        var id: String
        var revision: String
        var files: [String: File]
    }
    func prepare(progress: @escaping @Sendable (String) -> Void) async throws {
        try Task.checkCancellation()
        if model != nil { return }
        let manifestURL = Bundle.module.url(
            forResource: "model", withExtension: "json", subdirectory: "Resources")!
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(
                "Skill Issue/Models/\(manifest.revision)", isDirectory: true)
        for (index, path) in manifest.files.keys.sorted().enumerated() {
            try Task.checkCancellation()
            let info = manifest.files[path]!
            let target = directory.appendingPathComponent(path)
            let existing = try? Data(contentsOf: target, options: .mappedIfSafe)
            if let existing, existing.count == info.bytes,
                SHA256.hash(data: existing).map({ String(format: "%02x", $0) }).joined()
                    == info.sha256
            {
                continue
            }
            progress("Downloading speech model… \(index + 1)/\(manifest.files.count)")
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let url = URL(
                string: "https://huggingface.co/\(manifest.id)/resolve/\(manifest.revision)/\(path)"
            )!
            let (temporary, response) = try await URLSession.shared.download(from: url)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try Task.checkCancellation()
            let data = try Data(contentsOf: temporary, options: .mappedIfSafe)
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count == info.bytes,
                SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == info.sha256
            else { throw AppFailure.failed }
            try Task.checkCancellation()
            try data.write(to: target, options: .atomic)
        }
        try Task.checkCancellation()
        progress("Preparing speech…")
        do {
            model = try await NemotronStreamingASRModel.fromLocal(
                bundleDir: directory, computeUnits: .all)
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                queue.async { [self] in
                    do {
                        try autoreleasepool { try model!.warmUp() }
                        continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
            }
            try Task.checkCancellation()
        } catch {
            model = nil
            throw error
        }
    }
    func start(failed: @escaping @Sendable () -> Void) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    guard model != nil else { throw AppFailure.failed }
                    self.failed = failed
                    tracks = [:]
                    epoch = 0
                    active = true
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func receive(_ samples: [Float], source: AudioSource, seconds: Double) {
        let accepted = pendingLock.withLock { () -> Bool in
            guard pendingFrames + samples.count <= 16000 * 60 else { return false }
            pendingFrames += samples.count
            return true
        }
        guard accepted else {
            queue.async { [self] in failed?() }
            return
        }
        queue.async { [self] in
            defer { pendingLock.withLock { pendingFrames -= samples.count } }
            guard active else { return }
            do {
                let track: Track
                if let existing = tracks[source] {
                    track = existing
                } else {
                    track = try Track(model!.makeStreamingSession(language: nil))
                    tracks[source] = track
                }
                let audio = Double(track.frames) / 16000
                if track.spans.isEmpty || abs(track.time(audio) - seconds) > 0.05 {
                    track.spans.append((audio, seconds))
                }
                let updates = try autoreleasepool {
                    try track.session.push(
                        samples: samples, sampleRate: 16000, frameIndex: Int64(track.frames))
                }
                track.frames += samples.count
                if let last = updates.last {
                    track.update = last
                }
            } catch { failed?() }
        }
    }
    // Called synchronously from the serial capture queue so new captured chunks
    // are enqueued behind this cut. finish padding never carries into a new track.
    func freeze(completion: @escaping @Sendable (Result<[TranscriptSegment], Error>) -> Void) {
        queue.async { [self] in
            do {
                guard active else { throw AppFailure.failed }
                for track in tracks.values {
                    if let last = try autoreleasepool(invoking: { try track.session.finish() }).last
                    {
                        track.update = last
                    }
                }
                let batch = segments()
                tracks = [:]
                epoch += 1
                completion(.success(batch))
            } catch {
                if active { failed?() }
                completion(.failure(error))
            }
        }
    }
    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                active = false
                tracks = [:]
                failed = nil
                continuation.resume()
            }
        }
    }
    private func segments() -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        for source in [AudioSource.computer, .microphone] {
            guard let track = tracks[source], let update = track.update, !update.text.isEmpty else {
                continue
            }
            if update.words.isEmpty {
                let start = track.spans.first?.capture ?? 0
                result.append(
                    TranscriptSegment(
                        id: "\(epoch).\(source.rawValue).0", source: source, start: start,
                        end: track.time(Double(track.frames) / 16000), text: update.text))
                continue
            }
            var bucket = -1
            for word in update.words {
                let duration = Double(track.frames) / 16000
                let start = track.time(min(word.startTime, duration))
                let end = track.time(min(word.endTime, duration))
                let next = Int(max(0, start) / 4)
                if next != bucket {
                    result.append(
                        TranscriptSegment(
                            id: "\(epoch).\(source.rawValue).\(next)", source: source, start: start,
                            end: max(start, end), text: word.text))
                    bucket = next
                } else {
                    result[result.count - 1].text += " " + word.text
                    result[result.count - 1].end = max(start, end)
                }
            }
        }
        return result.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
    }
}
