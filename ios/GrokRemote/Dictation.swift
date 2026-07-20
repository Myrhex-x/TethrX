import Foundation
import Speech
import AVFoundation

/// On-device speech-to-text for the composer. Streams partial results into
/// `transcript` while recording; the chat view mirrors that into the draft.
@MainActor
final class Dictation: ObservableObject {
    @Published var isRecording = false
    @Published var transcript = ""

    private let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let engine = AVAudioEngine()
    private var base = ""   // draft text already present when recording started

    /// Whether speech recognition is usable at all (device + locale support).
    var supported: Bool { recognizer != nil }

    func toggle(base: String) { isRecording ? stop() : start(base: base) }

    func start(base: String) {
        self.base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        SFSpeechRecognizer.requestAuthorization { speech in
            guard speech == .authorized else { return }
            AVAudioApplication.requestRecordPermission { mic in
                Task { @MainActor in
                    guard mic else { return }
                    self.begin()
                }
            }
        }
    }

    func stop() { finish() }

    private func begin() {
        guard !isRecording, let recognizer, recognizer.isAvailable else { return }
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

    private func finish() {
        guard isRecording || engine.isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
