import Foundation
import Speech
import AVFoundation

/// On-device speech-to-text for the composer. Streams partial results into
/// `transcript` while recording; the chat view mirrors that into the draft.
@MainActor
final class Dictation: ObservableObject {
    @Published var isRecording = false
    @Published var transcript = ""
    /// Speech or microphone permission was refused. Without surfacing this, a denied
    /// permission made the mic button do nothing at all, forever, with no explanation.
    @Published var denied = false
    /// Recognition granted but unusable right now (Siri & Dictation off, locale
    /// unsupported, no network for this locale) — the other silent-no-op case.
    @Published var unavailable = false

    private let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let engine = AVAudioEngine()
    private var base = ""   // draft text already present when recording started
    /// Whether the bus-0 tap is installed. Tracked explicitly: installing twice
    /// raises an uncatchable NSException, and `finish()`'s old isRecording guard
    /// skipped the removal exactly when `engine.start()` had just thrown.
    private var tapInstalled = false

    /// Whether speech recognition is usable at all (device + locale support).
    var supported: Bool { recognizer != nil }

    func toggle(base: String) { isRecording ? stop() : start(base: base) }

    func start(base: String) {
        self.base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        SFSpeechRecognizer.requestAuthorization { speech in
            guard speech == .authorized else {
                Task { @MainActor in self.denied = true }
                return
            }
            AVAudioApplication.requestRecordPermission { mic in
                Task { @MainActor in
                    guard mic else { self.denied = true; return }
                    self.begin()
                }
            }
        }
    }

    func stop() { finish() }

    private func begin() {
        guard !isRecording else { return }
        guard let recognizer, recognizer.isAvailable else {
            unavailable = true       // the user just granted permissions; say why nothing happened
            return
        }
        unavailable = false
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audio.setActive(true, options: .notifyOthersOnDeactivation)

            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            request = req

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            // This closure runs on the realtime audio thread. Capture the request
            // directly rather than touching `self.request`, which is main-actor state
            // that finish() nils out — that was an unsynchronised read/write.
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                req.append(buffer)
            }
            tapInstalled = true
            engine.prepare()
            try engine.start()

            transcript = base
            isRecording = true
            Haptics.tap(.medium)

            task = recognizer.recognitionTask(with: req) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let result {
                        let spoken = result.bestTranscription.formattedString
                        self.transcript = self.base.isEmpty ? spoken : self.base + " " + spoken
                    }
                    if error != nil || (result?.isFinal ?? false) { self.finish() }
                }
            }
        } catch {
            finish()
        }
    }

    /// Tear everything down unconditionally. This must be safe to call from any
    /// half-started state: `begin()`'s catch runs it when `engine.start()` throws
    /// (audio hardware busy), where the tap IS installed but nothing else is —
    /// leaving it would crash the next recording with a double-install NSException.
    private func finish() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning { engine.stop() }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
