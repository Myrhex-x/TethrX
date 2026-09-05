import Foundation
import Speech
import AVFoundation

/// On-device speech-to-text for the composer.
///
/// The recogniser hands back the WHOLE utterance every time it revises, not the new
/// words, so the naive mirror of that into the draft ("draft = whatever it has heard
/// so far") fights the person holding the phone: delete a word while the mic is live
/// and the next partial result puts it straight back. The draft is therefore owned by
/// the composer, and this class owns only `spoken`, the current segment. When the
/// draft changes underneath it the composer calls `rebase(to:)`, which takes what is
/// on screen as the new starting point and cuts recognition over to a fresh segment,
/// so the next words extend the edit instead of undoing it.
@MainActor
final class Dictation: ObservableObject {
    @Published var isRecording = false
    /// `base` plus everything heard in the current segment: what the draft should say.
    @Published var transcript = ""
    /// Speech or microphone permission was refused. Without surfacing this, a denied
    /// permission made the mic button do nothing at all, forever, with no explanation.
    @Published var denied = false
    /// Recognition granted but unusable right now (Siri & Dictation off, locale
    /// unsupported, no network for this locale) — the other silent-no-op case.
    @Published var unavailable = false
    /// Rises and falls with the voice, for the meter on the mic button. A recording
    /// control that looks identical whether or not it can hear you is the other half
    /// of "the mic doesn't work".
    @Published var level: Double = 0

    /// The language speech is recognized in. Defaults to the app's locale — which
    /// follows the per-app language setting, NOT the language the user actually
    /// speaks (French speech in an English-set app came out garbled). Long-press
    /// the mic to change it; the choice persists.
    @Published var localeId: String {
        didSet {
            UserDefaults.standard.set(localeId, forKey: "dictation.locale")
            recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeId)) ?? SFSpeechRecognizer()
            // Mid-recording, swap language without dropping what is already written.
            if isRecording { rebase(to: transcript) }
        }
    }

    /// Text that was in the draft before the current segment started.
    private var base = ""
    /// What the recogniser has heard since the current segment started.
    private var spoken = ""

    private var recognizer: SFSpeechRecognizer?
    private var task: SFSpeechRecognitionTask?
    private let engine = AVAudioEngine()
    /// The audio tap runs on the realtime thread and must never touch main-actor
    /// state, but the request it feeds is replaced every time a segment restarts.
    /// A tiny locked box is the whole of the synchronisation.
    private let inbox = RequestBox()
    private var tapInstalled = false
    private var sessionActive = false

    private final class RequestBox: @unchecked Sendable {
        private let lock = NSLock()
        private var request: SFSpeechAudioBufferRecognitionRequest?
        func swap(_ new: SFSpeechAudioBufferRecognitionRequest?) -> SFSpeechAudioBufferRecognitionRequest? {
            lock.lock(); defer { lock.unlock() }
            let old = request; request = new; return old
        }
        func append(_ buffer: AVAudioPCMBuffer) {
            lock.lock(); defer { lock.unlock() }
            request?.append(buffer)
        }
    }

    init() {
        let saved = UserDefaults.standard.string(forKey: "dictation.locale")
        let id = saved ?? Locale.current.identifier
        localeId = id
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: id)) ?? SFSpeechRecognizer()
    }

    /// Languages worth offering: the device's preferred languages first, then the
    /// app's shipped languages — intersected with what SFSpeechRecognizer supports.
    static var languageChoices: [(id: String, label: String)] {
        let preferred = Locale.preferredLanguages
        let appLangs = ["en-US", "fr-FR", "es-ES", "de-DE", "it-IT", "pt-BR", "ja-JP", "zh-CN"]
        // Sorted: supportedLocales() is a Set, and hash-order .first{} made the
        // offered variant nondeterministic (zh could land on TW, HK, or CN).
        let supported = SFSpeechRecognizer.supportedLocales().sorted { $0.identifier < $1.identifier }
        var seen = Set<String>()
        var out: [(String, String)] = []
        for raw in preferred + appLangs {
            // Exact locale first, else a variant of the same LANGUAGE — matched via
            // Locale's language code, not prefix(2), which mangled 3-letter codes
            // ("fil" is Filipino, not Finnish). Prefer the variant whose region
            // matches ("zh-Hans-CN" → zh_CN), else the first sorted one.
            let rawLocale = Locale(identifier: raw)
            let exact = supported.first { $0.identifier.replacingOccurrences(of: "_", with: "-") == raw }
            let lang = rawLocale.language.languageCode?.identifier
            let sameLang = supported.filter { $0.language.languageCode?.identifier == lang }
            let candidate = exact
                ?? sameLang.first { $0.region?.identifier == rawLocale.region?.identifier }
                ?? sameLang.first
            guard let locale = candidate else { continue }
            let id = locale.identifier
            guard seen.insert(id).inserted else { continue }
            let label = Locale.current.localizedString(forIdentifier: id) ?? id
            out.append((id, label))
        }
        return out
    }

    var currentLanguageLabel: String {
        Locale.current.localizedString(forIdentifier: localeId) ?? localeId
    }

    /// Whether speech recognition is usable at all (device + locale support).
    var supported: Bool { recognizer != nil }

    func toggle(base: String) { isRecording ? stop() : start(base: base) }

    func start(base: String) {
        self.base = base.trimmingCharacters(in: .whitespacesAndNewlines)
        self.spoken = ""
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

    /// The composer's text changed under us: adopt it and start a new segment.
    ///
    /// A new segment, not a new offset into the old one. The recogniser revises words
    /// it has already reported ("hello world" becomes "Hello, world."), so no amount
    /// of prefix arithmetic can reliably subtract what it said before the edit. Ending
    /// the request is the only honest cut, and the audio engine keeps running across
    /// it, so nothing is lost but the half-second of speech in flight.
    func rebase(to text: String) {
        base = text.trimmingCharacters(in: .whitespacesAndNewlines)
        spoken = ""
        transcript = text
        guard isRecording else { return }
        openSegment()
    }

    private var combined: String {
        guard !spoken.isEmpty else { return base }
        return base.isEmpty ? spoken : base + " " + spoken
    }

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
            sessionActive = true

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            // A zero-rate format means the route is not ready. installTap raises an
            // uncatchable NSException on one, so this has to be a guard, not a throw.
            guard format.sampleRate > 0, format.channelCount > 0 else {
                unavailable = true
                finish()
                return
            }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [inbox] buffer, _ in
                inbox.append(buffer)
                // Peak of the frame, as a rough 0...1 loudness for the meter.
                guard let data = buffer.floatChannelData?[0] else { return }
                var peak: Float = 0
                for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(data[i])) }
                let value = Double(min(1, peak * 3))
                Task { @MainActor [weak self] in
                    guard let self, self.isRecording else { return }
                    self.level = self.level * 0.7 + value * 0.3
                }
            }
            tapInstalled = true
            engine.prepare()
            try engine.start()

            transcript = base
            isRecording = true
            Haptics.tap(.medium)
            openSegment()
        } catch {
            finish()
        }
    }

    /// Start (or restart) one recognition request. The tap keeps feeding whichever
    /// request is currently in the box.
    private func openSegment() {
        guard let recognizer else { return }
        task?.cancel()
        task = nil

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        // Punctuation is most of what separates dictated text from a transcript.
        req.addsPunctuation = true
        // On-device where the language supports it: no network dependency, no
        // server-side minute cap, and nothing spoken here leaves the phone — which is
        // the same promise the rest of the app makes.
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        inbox.swap(req)?.endAudio()

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.isRecording else { return }
                if let result {
                    self.spoken = result.bestTranscription.formattedString
                    self.transcript = self.combined
                }
                guard error != nil || (result?.isFinal ?? false) else { return }
                if error == nil {
                    // Recognition finalises itself after a pause, or after about a
                    // minute of audio. Stopping there is what made long dictation look
                    // broken: commit what it heard and open the next segment instead.
                    self.base = self.combined
                    self.spoken = ""
                    self.openSegment()
                } else {
                    self.finish()
                }
            }
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
        inbox.swap(nil)?.endAudio()
        task?.cancel()
        task = nil
        isRecording = false
        level = 0
        if sessionActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            sessionActive = false
        }
    }
}

/// Transcribing an audio FILE the user attached.
///
/// The bridge speaks text: a prompt carries words and images, and there is nowhere
/// for a waveform to go. So an attached recording is turned into words here, on the
/// phone, before it is ever part of a message — which is both the only thing that
/// would work and the only thing consistent with a token that never leaves the
/// device.
enum AudioTranscription {
    enum Failure: LocalizedError {
        case denied, unsupported, empty
        var errorDescription: String? {
            switch self {
            case .denied:      return String(loc: "TethrX needs permission to use speech recognition. Turn it on in Settings.")
            case .unsupported: return String(loc: "Speech recognition isn't available for this language right now.")
            case .empty:       return String(loc: "No speech was recognized in that recording.")
            }
        }
    }

    static func authorize() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
    }

    static func text(from url: URL, localeId: String) async throws -> String {
        guard await authorize() else { throw Failure.denied }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeId)) ?? SFSpeechRecognizer(),
              recognizer.isAvailable else { throw Failure.unsupported }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        // A file has no length limit on device; over the network it would be capped
        // and would also send the recording to Apple, which this app should not do.
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }

        let text: String = try await withCheckedThrowingContinuation { cont in
            // `recognitionTask` can call back more than once even with partials off
            // (a final result, then an error as the task tears down). Resuming a
            // continuation twice is a crash, so the first answer wins and the rest
            // are dropped.
            let once = OnceBox(cont)
            recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    once.succeed(result.bestTranscription.formattedString)
                } else if let error {
                    once.fail(error)
                }
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.empty }
        return trimmed
    }

    private final class OnceBox: @unchecked Sendable {
        private let lock = NSLock()
        private var cont: CheckedContinuation<String, Error>?
        init(_ cont: CheckedContinuation<String, Error>) { self.cont = cont }
        private func take() -> CheckedContinuation<String, Error>? {
            lock.lock(); defer { lock.unlock() }
            let c = cont; cont = nil; return c
        }
        func succeed(_ value: String) { take()?.resume(returning: value) }
        func fail(_ error: Error) { take()?.resume(throwing: error) }
    }
}
