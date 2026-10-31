import Foundation
import AVFoundation
import CoreGraphics
import Speech

struct FrameNote: Codable, Hashable, Sendable {
    var time: Double
    var sceneStart: Bool
    var caption: String?
    var labels: [String]
    var ocr: String
}

struct TranscriptSegment: Codable, Hashable, Sendable {
    var start: Double
    var end: Double
    var text: String
}

/// Timestamped, text-based description of a video, built entirely on device. The language model answers questions
/// from this dossier (and from the frames themselves when a vision model is loaded), so videos are never uploaded.
struct VideoDossier: Codable, Sendable {
    var fileName: String
    var duration: Double
    var width: Int
    var height: Int
    var fps: Double
    var codec: String
    var hasAudio: Bool
    var fileSize: Int64
    var frames: [FrameNote] = []
    var sceneStarts: [Double] = []
    var transcript: [TranscriptSegment] = []
    var notes: [String] = []

    static func stamp(_ t: Double) -> String {
        let s = Int(t.rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    var header: String {
        "\(fileName): \(Self.stamp(duration)) long, \(width)×\(height), \(String(format: "%.0f", fps)) fps, \(codec), " +
        "\(hasAudio ? "with audio" : "no audio"), \(ByteCountFormatter.file(fileSize))"
    }

    /// Text for the language model. With `focus`, includes full detail within ±45 s of that time and a sparse overview
    /// elsewhere; otherwise distributes the character budget evenly across the timeline.
    func text(budget: Int, focus: Double? = nil) -> String {
        var out = "VIDEO \(header)\n"
        if !sceneStarts.isEmpty { out += "Scene changes at: " + sceneStarts.prefix(40).map(Self.stamp).joined(separator: ", ") + "\n" }
        func near(_ t: Double) -> Bool { focus.map { abs($0 - t) <= 45 } ?? true }
        var timeline = "Visual timeline:\n"
        for f in frames {
            let detail = near(f.time)
            var line = "[\(Self.stamp(f.time))]" + (f.sceneStart ? " New scene." : "")
            if let c = f.caption, !c.isEmpty { line += " \(c)" }
            if !f.labels.isEmpty { line += " Detected: \(f.labels.prefix(detail ? 5 : 2).joined(separator: ", "))." }
            if !f.ocr.isEmpty && detail { line += " On-screen text: “\(f.ocr.replacingOccurrences(of: "\n", with: " ").truncated(to: 160))”." }
            timeline += line + "\n"
        }
        var speech = transcript.isEmpty ? "" : "Transcript (on-device speech recognition):\n"
        for seg in transcript {
            let detail = near(seg.start)
            speech += "[\(Self.stamp(seg.start))–\(Self.stamp(seg.end))] \(detail ? seg.text : seg.text.truncated(to: 80))\n"
        }
        let notesText = notes.isEmpty ? "" : "Processing notes: " + notes.joined(separator: " ") + "\n"
        let half = max(400, (budget - out.count - notesText.count) / 2)
        out += Self.sample(timeline, limit: transcript.isEmpty ? half * 2 : half)
        out += Self.sample(speech, limit: half)
        out += notesText
        return out
    }

    /// Keeps evenly spaced lines when text exceeds the limit (preserves coverage of the whole timeline).
    private static func sample(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let lines = text.components(separatedBy: "\n")
        let keep = max(2, lines.count * limit / max(1, text.count))
        let step = Double(lines.count) / Double(keep)
        var picked: [String] = []
        var i = 0.0
        while Int(i) < lines.count { picked.append(lines[Int(i)]); i += step }
        return picked.joined(separator: "\n") + "\n(… timeline sampled to fit the context window)\n"
    }

    /// Parses "2:30", "at 150 seconds", "2 minutes and 30 seconds" from a question.
    static func focusTime(in question: String) -> Double? {
        let q = question.lowercased()
        if let r = q.range(of: #"(\d{1,2}):(\d{2})(?::(\d{2}))?"#, options: .regularExpression) {
            let parts = q[r].split(separator: ":").compactMap { Double($0) }
            if parts.count == 3 { return parts[0] * 3600 + parts[1] * 60 + parts[2] }
            if parts.count == 2 { return parts[0] * 60 + parts[1] }
        }
        var total: Double = 0
        var found = false
        if let r = q.range(of: #"(\d+(?:\.\d+)?)\s*(minutes?|mins?)"#, options: .regularExpression),
           let v = Double(q[r].prefix { $0.isNumber || $0 == "." }) { total += v * 60; found = true }
        if let r = q.range(of: #"(\d+)\s*(seconds?|secs?|s\b)"#, options: .regularExpression),
           let v = Double(q[r].prefix { $0.isNumber }) { total += v; found = true }
        return found ? total : nil
    }
}

enum VideoAnalyzer {
    struct Options: Sendable {
        var keyframes: Int
        var captions: Int
        var transcribeMinutes: Double
        var transcribe: Bool
        var requireOnDeviceSpeech: Bool

        static func forMode(_ m: IntelligenceMode, transcribe: Bool, offline: Bool) -> Options {
            switch m {
            case .instant: return Options(keyframes: 8, captions: 0, transcribeMinutes: 2, transcribe: transcribe, requireOnDeviceSpeech: offline)
            case .thinking: return Options(keyframes: 16, captions: 8, transcribeMinutes: 10, transcribe: transcribe, requireOnDeviceSpeech: offline)
            case .max: return Options(keyframes: 32, captions: 16, transcribeMinutes: 30, transcribe: transcribe, requireOnDeviceSpeech: offline)
            }
        }
    }

    static let maxFileBytes: Int64 = 4 * 1_073_741_824

    /// `captioner` (optional) describes a frame with a vision-language model; called for at most `options.captions` frames.
    static func analyze(url: URL, options: Options, captioner: ((CGImage) async -> String?)?,
                        progress: @escaping (String) -> Void) async throws -> VideoDossier {
        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard size <= maxFileBytes else {
            throw NexusError.generic("This video is \(ByteCountFormatter.file(size)). NEXUS analyzes videos up to 4 GB on device. Trim it in Photos first.")
        }
        let asset = AVURLAsset(url: url)
        progress("Reading video metadata")
        guard try await asset.load(.isPlayable) else {
            throw NexusError.generic("This video's format or codec isn't supported by iOS, so it can't be analyzed.")
        }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw NexusError.generic("Couldn't determine the video's duration.") }
        let vTrack = try await asset.loadTracks(withMediaType: .video).first
        guard let vTrack else { throw NexusError.generic("No video track found.") }
        let natural = try await vTrack.load(.naturalSize)
        let transform = try await vTrack.load(.preferredTransform)
        let display = CGRect(origin: .zero, size: natural).applying(transform)
        let fps = Double(try await vTrack.load(.nominalFrameRate))
        let formats = try await vTrack.load(.formatDescriptions)
        let codec = formats.first.map { Self.fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? "unknown"
        let hasAudio = !(try await asset.loadTracks(withMediaType: .audio)).isEmpty
        var dossier = VideoDossier(fileName: url.lastPathComponent, duration: duration, width: Int(abs(display.width)),
                                   height: Int(abs(display.height)), fps: fps, codec: codec, hasAudio: hasAudio, fileSize: size)

        // 1. Scene-change detection on low-resolution samples.
        progress("Detecting scene changes")
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 64, height: 64)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        let sampleStep = max(0.5, duration / 300)
        var previous: [Float]?
        var scenes: [Double] = [0]
        var t = 0.0
        while t < duration {
            if Task.isCancelled { throw NexusError.cancelled }
            if let frame = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image {
                let lum = luminance(frame)
                if let prev = previous, lum.count == prev.count, !lum.isEmpty {
                    var diff: Float = 0
                    for i in 0..<lum.count { diff += abs(lum[i] - prev[i]) }
                    diff /= Float(lum.count)
                    if diff > 0.16, t - (scenes.last ?? 0) > 1.5 { scenes.append(t) }
                }
                previous = lum
            }
            t += sampleStep
        }
        dossier.sceneStarts = scenes

        // 2. Key frames: scene starts plus even coverage.
        var times = Set(scenes.prefix(options.keyframes).map { ($0 * 10).rounded() / 10 })
        let uniform = max(1, options.keyframes - times.count)
        for i in 0..<uniform { times.insert(((duration * (Double(i) + 0.5) / Double(uniform)) * 10).rounded() / 10) }
        var keyTimes = times.sorted()
        if keyTimes.count > options.keyframes {
            let stride = Double(keyTimes.count) / Double(options.keyframes)
            keyTimes = (0..<options.keyframes).map { keyTimes[Int(Double($0) * stride)] }
        }

        let detail = AVAssetImageGenerator(asset: asset)
        detail.appliesPreferredTrackTransform = true
        detail.maximumSize = CGSize(width: 768, height: 768)
        var captioned = 0
        for (i, kt) in keyTimes.enumerated() {
            if Task.isCancelled { throw NexusError.cancelled }
            progress("Analyzing frame \(i + 1) of \(keyTimes.count) (\(VideoDossier.stamp(kt)))")
            guard let frame = try? await detail.image(at: CMTime(seconds: kt, preferredTimescale: 600)).image else { continue }
            let analysis = await VisionAnalyzer.analyze(frame)
            var caption: String?
            if let captioner, captioned < options.captions {
                caption = await captioner(frame)
                captioned += 1
            }
            dossier.frames.append(FrameNote(time: kt, sceneStart: scenes.contains { abs($0 - kt) < 0.6 }, caption: caption,
                                            labels: analysis.labels.map { $0.0.replacingOccurrences(of: "_", with: " ") },
                                            ocr: analysis.text))
        }
        if captioner == nil { dossier.notes.append("Frames were described with Apple Vision labels and OCR only (no vision-language model loaded).") }
        else if captioned < keyTimes.count { dossier.notes.append("\(captioned) of \(keyTimes.count) key frames have detailed captions.") }

        // 3. Speech transcription (on device when supported).
        if hasAudio && options.transcribe {
            do {
                let (segments, note) = try await transcribe(asset: asset, duration: duration, options: options, progress: progress)
                dossier.transcript = segments
                if let note { dossier.notes.append(note) }
            } catch {
                dossier.notes.append("Audio was not transcribed: \(error.localizedDescription)")
            }
        } else if hasAudio {
            dossier.notes.append("Audio transcription is turned off.")
        }
        dossier.notes.append("Speaker separation and object tracking are not available on device.")
        return dossier
    }

    private static func luminance(_ image: CGImage) -> [Float] {
        let w = 16, h = 9
        var px = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return [] }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return px.map { Float($0) / 255 }
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        let s = String(bytes: [UInt8((code >> 24) & 0xff), UInt8((code >> 16) & 0xff), UInt8((code >> 8) & 0xff), UInt8(code & 0xff)], encoding: .ascii) ?? "?"
        switch s {
        case "avc1": return "H.264"
        case "hvc1", "hev1": return "HEVC"
        case "ap4h", "apcn", "apch": return "ProRes"
        default: return s.trimmed
        }
    }

    private static func transcribe(asset: AVURLAsset, duration: Double, options: Options,
                                   progress: @escaping (String) -> Void) async throws -> ([TranscriptSegment], String?) {
        let authorized = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        guard authorized else { throw NexusError.generic("Speech recognition permission was not granted.") }
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else {
            throw NexusError.generic("No speech recognizer for this language.")
        }
        if options.requireOnDeviceSpeech && !recognizer.supportsOnDeviceRecognition {
            throw NexusError.generic("On-device recognition isn't available for \(recognizer.locale.identifier), and Offline-Only mode forbids server recognition.")
        }
        let limit = min(duration, options.transcribeMinutes * 60)
        var segments: [TranscriptSegment] = []
        var start = 0.0
        let chunk = 55.0
        while start < limit {
            if Task.isCancelled { throw NexusError.cancelled }
            let length = min(chunk, limit - start)
            progress("Transcribing audio \(VideoDossier.stamp(start))–\(VideoDossier.stamp(start + length))")
            guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { break }
            let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
            export.outputURL = out
            export.outputFileType = .m4a
            export.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                           duration: CMTime(seconds: length, preferredTimescale: 600))
            let ok: Bool = await withCheckedContinuation { c in export.exportAsynchronously { c.resume(returning: export.status == .completed) } }
            defer { try? FileManager.default.removeItem(at: out) }
            guard ok else { start += chunk; continue }
            let req = SFSpeechURLRecognitionRequest(url: out)
            req.requiresOnDeviceRecognition = options.requireOnDeviceSpeech || recognizer.supportsOnDeviceRecognition
            req.addsPunctuation = true
            req.shouldReportPartialResults = false
            let words: [(Double, Double, String)] = await withCheckedContinuation { c in
                let once = OnceFlag()
                recognizer.recognitionTask(with: req) { @Sendable result, error in
                    if let result, result.isFinal, once.claim() {
                        c.resume(returning: result.bestTranscription.segments.map { ($0.timestamp, $0.duration, $0.substring) })
                    } else if error != nil, once.claim() {
                        c.resume(returning: [])
                    }
                }
            }
            // Group words into ~8-second segments.
            var bucket: [String] = []
            var bucketStart: Double?
            var lastEnd = 0.0
            for (ts, dur, w) in words {
                if bucketStart == nil { bucketStart = ts }
                bucket.append(w)
                lastEnd = ts + dur
                if lastEnd - (bucketStart ?? 0) >= 8 {
                    segments.append(TranscriptSegment(start: start + (bucketStart ?? 0), end: start + lastEnd, text: bucket.joined(separator: " ")))
                    bucket = []
                    bucketStart = nil
                }
            }
            if !bucket.isEmpty {
                segments.append(TranscriptSegment(start: start + (bucketStart ?? 0), end: start + lastEnd, text: bucket.joined(separator: " ")))
            }
            start += chunk
        }
        let note = limit < duration ? "Audio transcribed for the first \(VideoDossier.stamp(limit)) (\(Int(options.transcribeMinutes)) min limit in this mode)." : nil
        return (segments, note)
    }
}

/// Ensures a continuation is resumed exactly once from callbacks that may fire repeatedly.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
