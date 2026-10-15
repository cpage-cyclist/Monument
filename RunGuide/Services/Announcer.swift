import AVFoundation

/// Speaks cues over whatever you're listening to (music ducks while it talks).
final class Announcer: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var sessionActive = false

    override init() {
        super.init()
        synthesizer.delegate = self
        prepare()
    }

    func prepare() {
        try? AVAudioSession.sharedInstance().setCategory(
            .playback,
            mode: .voicePrompt,
            options: [.mixWithOthers, .duckOthers]
        )
    }

    func speak(_ text: String) {
        activate()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.bestVoice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    func stopAll() {
        synthesizer.stopSpeaking(at: .immediate)
        deactivate()
    }

    /// The highest-quality British English voice on the phone. Premium and
    /// Enhanced voices sound far less robotic but must be downloaded first:
    /// Settings › Accessibility › Spoken Content › Voices › English › English (UK).
    static var bestVoice: AVSpeechSynthesisVoice? {
        let british = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "en-GB" }
        let best = british.max { a, b in
            if a.quality.rawValue != b.quality.rawValue { return a.quality.rawValue < b.quality.rawValue }
            // Prefer non-novelty voices at the same quality.
            return a.voiceTraits.contains(.isNoveltyVoice) && !b.voiceTraits.contains(.isNoveltyVoice)
        }
        return best ?? AVSpeechSynthesisVoice(language: "en-GB")
    }

    static var voiceDescription: String {
        guard let voice = bestVoice else { return "Default voice" }
        switch voice.quality {
        case .premium: return "\(voice.name) (Premium)"
        case .enhanced: return "\(voice.name) (Enhanced)"
        default: return "\(voice.name) (basic)"
        }
    }

    private func activate() {
        guard !sessionActive else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        sessionActive = true
    }

    private func deactivate() {
        guard sessionActive else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        sessionActive = false
    }

    // Release the audio session between cues so music comes back to full volume.
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        if !synthesizer.isSpeaking { deactivate() }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        if !synthesizer.isSpeaking { deactivate() }
    }
}
