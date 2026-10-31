import Foundation
import AVFoundation
import Speech

/// Hands-free voice conversation: on-device speech recognition, voice-activity detection (end-of-utterance by
/// silence), sentence-level streaming text-to-speech, and barge-in (speaking interrupts the assistant).
@MainActor
final class VoiceEngine: NSObject, ObservableObject {
    enum State: Equatable { case idle, listening, thinking, speaking, error(String) }

    @Published private(set) var state: State = .idle
    @Published private(set) var transcript = ""
    @Published private(set) var level: Float = 0
    @Published private(set) var onDevice = false

    var onUtterance: ((String) -> Void)?
    var requireOnDevice = true
    var voiceIdentifier = ""
    var rate: Float = AVSpeechUtteranceDefaultSpeechRate

    private let audio = AVAudioEngine()
    private let synth = AVSpeechSynthesizer()
    private var recognizer: SFSpeechRecognizer?
    private let requestBox = RecognitionRequestBox()
    private var request: SFSpeechAudioBufferRecognitionRequest? {
        get { requestBox.value }
        set { requestBox.value = newValue }
    }
    private var task: SFSpeechRecognitionTask?
    private var lastVoice = Date()
    private var heardSpeech = false
    private var vadTimer: Timer?
    private var bargeInSince: Date?
    private var pendingSpeech = ""
    private var generationDone = true
    private var queuedUtterances = 0

    // VAD thresholds (dBFS)
    private let speechThreshold: Float = -38
    private let bargeInThreshold: Float = -28
    private let endOfUtteranceSilence: TimeInterval = 1.2

    override init() {
        super.init()
        synth.delegate = self
    }

    static func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        let mic = await AVAudioApplication.requestRecordPermission()
        return speech && mic
    }

    func start() async {
        guard await Self.requestPermissions() else {
            state = .error("Microphone and speech recognition permissions are required. Enable them in Settings.")
            return
        }
        recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let recognizer, recognizer.isAvailable || recognizer.supportsOnDeviceRecognition else {
            state = .error("Speech recognition is not available for this language.")
            return
        }
        if requireOnDevice && !recognizer.supportsOnDeviceRecognition {
            state = .error("On-device speech recognition isn't available for \(recognizer.locale.identifier). Turn off Offline-Only to use server recognition, or change your language.")
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let input = audio.inputNode
            let format = input.outputFormat(forBus: 0)
            input.removeTap(onBus: 0)
            let box = requestBox
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable [weak self] buffer, _ in
                let db = VoiceEngine.decibels(buffer)
                box.value?.append(buffer)
                Task { @MainActor in self?.process(level: db) }
            }
            audio.prepare()
            try audio.start()
            startRecognition()
            vadTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.checkEndOfUtterance() }
            }
        } catch {
            state = .error("Audio error: \(error.localizedDescription)")
        }
    }

    func stop() {
        vadTimer?.invalidate()
        vadTimer = nil
        task?.cancel()
        task = nil
        request = nil
        audio.inputNode.removeTap(onBus: 0)
        audio.stop()
        synth.stopSpeaking(at: .immediate)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        state = .idle
        level = 0
    }

    private func startRecognition() {
        guard let recognizer else { return }
        task?.cancel()
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        req.requiresOnDeviceRecognition = requireOnDevice || recognizer.supportsOnDeviceRecognition
        onDevice = req.requiresOnDeviceRecognition
        request = req
        transcript = ""
        heardSpeech = false
        lastVoice = Date()
        state = .listening
        task = recognizer.recognitionTask(with: req) { @Sendable [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            Task { @MainActor in
                guard let self else { return }
                if let text, self.state == .listening { self.transcript = text }
                if error != nil, self.state == .listening, self.transcript.isEmpty {
                    // Recognition sessions time out after ~1 minute of silence; restart quietly.
                    self.startRecognition()
                }
            }
        }
    }

    nonisolated static func decibels(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return -160 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return -160 }
        var sum: Float = 0
        for i in 0..<n { sum += data[i] * data[i] }
        let rms = sqrt(sum / Float(n))
        return 20 * log10(max(rms, 1e-7))
    }

    private func process(level db: Float) {
        level = max(0, min(1, (db + 60) / 50))
        switch state {
        case .listening:
            if db > speechThreshold { lastVoice = Date(); heardSpeech = true }
        case .speaking:
            // Barge-in: sustained loud input while the assistant talks.
            if db > bargeInThreshold {
                if bargeInSince == nil { bargeInSince = Date() }
                if let s = bargeInSince, Date().timeIntervalSince(s) > 0.3 { interrupt() }
            } else {
                bargeInSince = nil
            }
        default: break
        }
    }

    private func checkEndOfUtterance() {
        guard state == .listening, heardSpeech, !transcript.trimmed.isEmpty,
              Date().timeIntervalSince(lastVoice) > endOfUtteranceSilence else { return }
        let text = transcript.trimmed
        request?.endAudio()
        task?.finish()
        request = nil
        state = .thinking
        generationDone = false
        pendingSpeech = ""
        onUtterance?(text)
    }

    /// Stop speaking immediately and listen again.
    func interrupt() {
        bargeInSince = nil
        synth.stopSpeaking(at: .immediate)
        queuedUtterances = 0
        pendingSpeech = ""
        NotificationCenter.default.post(name: .nexusVoiceInterrupted, object: nil)
        startRecognition()
    }

    // MARK: Streaming TTS

    /// Feed streamed response text; complete sentences are spoken as soon as they arrive.
    func speak(delta: String) {
        pendingSpeech += delta
        // Speak each complete sentence as soon as it arrives (minimum ~12 characters per utterance so very short
        // fragments are merged with the next sentence instead of blocking the queue).
        while pendingSpeech.count > 12 {
            let searchStart = pendingSpeech.index(pendingSpeech.startIndex, offsetBy: 12)
            guard let r = pendingSpeech.range(of: #"[.!?:;](\s|$)|\n"#, options: .regularExpression,
                                              range: searchStart..<pendingSpeech.endIndex) else { break }
            let sentence = String(pendingSpeech[..<r.upperBound])
            pendingSpeech = String(pendingSpeech[r.upperBound...])
            enqueue(sentence)
        }
    }

    func finishSpeaking() {
        enqueue(pendingSpeech)
        pendingSpeech = ""
        generationDone = true
        if queuedUtterances == 0 && state != .idle { startRecognition() }
    }

    private func enqueue(_ text: String) {
        let clean = Self.speakable(text)
        guard !clean.isEmpty else { return }
        let u = AVSpeechUtterance(string: clean)
        if let v = AVSpeechSynthesisVoice(identifier: voiceIdentifier) { u.voice = v }
        else { u.voice = Self.bestVoice() }
        u.rate = rate
        queuedUtterances += 1
        state = .speaking
        synth.speak(u)
    }

    static func speakable(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: "```[\\s\\S]*?```", with: " (code omitted) ", options: .regularExpression)
        s = s.replacingOccurrences(of: "[*_#`>|]", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\[(\\d+)\\]", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]+\\)", with: "$1", options: .regularExpression)
        return s.trimmed
    }

    static func bestVoice() -> AVSpeechSynthesisVoice? {
        let lang = AVSpeechSynthesisVoice.currentLanguageCode()
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == lang }
        return voices.first { $0.quality == .premium } ?? voices.first { $0.quality == .enhanced } ?? AVSpeechSynthesisVoice(language: lang)
    }

    static func availableVoices() -> [AVSpeechSynthesisVoice] {
        let prefix = String(AVSpeechSynthesisVoice.currentLanguageCode().prefix(2))
        return AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(prefix) }
            .sorted { ($0.quality.rawValue, $0.name) > ($1.quality.rawValue, $1.name) }
    }
}

extension VoiceEngine: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.queuedUtterances = max(0, self.queuedUtterances - 1)
            if self.queuedUtterances == 0 && self.generationDone && self.state == .speaking {
                self.startRecognition()
            }
        }
    }
}

/// One-shot dictation for the chat composer.
@MainActor
final class Dictation: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var text = ""
    private let audio = AVAudioEngine()
    private let requestBox = RecognitionRequestBox()
    private var request: SFSpeechAudioBufferRecognitionRequest? {
        get { requestBox.value }
        set { requestBox.value = newValue }
    }
    private var task: SFSpeechRecognitionTask?

    func toggle(requireOnDevice: Bool) async {
        if isRecording { stop(); return }
        guard await VoiceEngine.requestPermissions(),
              let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")) else { return }
        if requireOnDevice && !recognizer.supportsOnDeviceRecognition { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement)
            try AVAudioSession.sharedInstance().setActive(true)
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            req.addsPunctuation = true
            req.requiresOnDeviceRecognition = requireOnDevice || recognizer.supportsOnDeviceRecognition
            request = req
            let input = audio.inputNode
            input.removeTap(onBus: 0)
            let box = requestBox
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { @Sendable b, _ in box.value?.append(b) }
            audio.prepare()
            try audio.start()
            text = ""
            isRecording = true
            task = recognizer.recognitionTask(with: req) { @Sendable [weak self] result, error in
                let t = result?.bestTranscription.formattedString
                let final = result?.isFinal ?? false
                Task { @MainActor in
                    if let t { self?.text = t }
                    if final || error != nil { self?.stop() }
                }
            }
        } catch {
            stop()
        }
    }

    func stop() {
        request?.endAudio()
        task?.finish()
        audio.inputNode.removeTap(onBus: 0)
        audio.stop()
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

extension Notification.Name {
    static let nexusVoiceInterrupted = Notification.Name("nexus.voice.interrupted")
}

/// Lets the realtime audio thread hand buffers to the current recognition request without touching main-actor state.
final class RecognitionRequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: SFSpeechAudioBufferRecognitionRequest?
    var value: SFSpeechAudioBufferRecognitionRequest? {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}
