import SwiftUI

/// Full-screen, hands-free voice conversation.
struct VoiceView: View {
    @ObservedObject var chat: ChatViewModel
    @ObservedObject var settings: SettingsStore
    @StateObject private var voice = VoiceEngine()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            VStack(spacing: 28) {
                HStack {
                    Pill(text: chat.mode.title, symbol: chat.mode.symbol, tint: chat.mode.tint)
                    Spacer()
                    if voice.onDevice { Pill(text: "On-device speech", symbol: "lock.fill", tint: .green) }
                }
                .padding(.horizontal)
                Spacer()
                Orb(level: voice.level, state: voice.state)
                    .frame(width: 220, height: 220)
                    .onTapGesture {
                        if case .speaking = voice.state { voice.interrupt() }
                    }
                    .accessibilityLabel(stateLabel)
                    .accessibilityHint("Tap while NEXUS is speaking to interrupt")
                Text(stateLabel).font(.headline).foregroundStyle(.secondary)
                ScrollView {
                    VStack(spacing: 14) {
                        if !voice.transcript.isEmpty {
                            Text(voice.transcript).font(.title3).multilineTextAlignment(.center)
                        }
                        if let s = chat.session, !s.text.isEmpty {
                            Text(s.text).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        } else if let last = chat.conversation.messages.last, last.role == .assistant, voice.state != .listening {
                            Text(last.content).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(8)
                        }
                    }
                    .padding(.horizontal, 24)
                }
                .frame(maxHeight: 220)
                Spacer()
                HStack(spacing: 40) {
                    Button {
                        voice.interrupt()
                        chat.stop()
                    } label: {
                        Image(systemName: "hand.raised.fill").font(.title2).frame(width: 64, height: 64)
                            .background(Color(uiColor: .tertiarySystemFill), in: Circle())
                    }
                    .accessibilityLabel("Interrupt")
                    Button {
                        voice.stop()
                        chat.stop()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark").font(.title2.weight(.semibold)).foregroundStyle(.white)
                            .frame(width: 64, height: 64).background(Color.red, in: Circle())
                    }
                    .accessibilityLabel("End voice conversation")
                }
                .padding(.bottom, 30)
            }
            .padding(.top, 20)
        }
        .task {
            voice.requireOnDevice = settings.offlineOnly
            voice.voiceIdentifier = settings.voiceIdentifier
            voice.rate = Float(settings.speechRate)
            voice.onUtterance = { text in chat.send(text) }
            chat.onStreamDelta = { delta in if settings.speakResponses { voice.speak(delta: delta) } }
            chat.onTurnFinished = { voice.finishSpeaking() }
            await voice.start()
        }
        .onDisappear {
            voice.stop()
            chat.onStreamDelta = nil
            chat.onTurnFinished = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .nexusVoiceInterrupted)) { _ in chat.stop() }
    }

    private var stateLabel: String {
        switch voice.state {
        case .idle: return "Starting…"
        case .listening: return "Listening"
        case .thinking: return chat.session?.status.isEmpty == false ? chat.session!.status : "Thinking"
        case .speaking: return "Speaking — tap or talk to interrupt"
        case .error(let e): return e
        }
    }
}

struct Orb: View {
    var level: Float
    var state: VoiceEngine.State
    @State private var phase = false

    var body: some View {
        let scale = 0.85 + CGFloat(level) * 0.35
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [tint.opacity(0.55), tint.opacity(0.08)], center: .center, startRadius: 10, endRadius: 120))
                .scaleEffect(state == .thinking ? (phase ? 1.05 : 0.92) : scale)
                .animation(state == .thinking ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .easeOut(duration: 0.12), value: state == .thinking ? phase : (level > 0))
            Circle().stroke(tint.opacity(0.6), lineWidth: 2).scaleEffect(scale * 0.7)
            Image(systemName: symbol).font(.system(size: 40, weight: .light)).foregroundStyle(tint)
        }
        .onAppear { phase = true }
    }

    private var tint: Color {
        switch state {
        case .listening: return .accentColor
        case .thinking: return .purple
        case .speaking: return .green
        case .error: return .red
        case .idle: return .secondary
        }
    }

    private var symbol: String {
        switch state {
        case .listening: return "waveform"
        case .thinking: return "sparkles"
        case .speaking: return "speaker.wave.2"
        case .error: return "exclamationmark.triangle"
        case .idle: return "mic"
        }
    }
}
