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
        utterance.voice = Self.selectedVoice
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

    static let voiceKey = "voiceIdentifier"

    /// The voice chosen in Settings, or the best UK voice if none is chosen
    /// (or the chosen one has since been deleted from the phone).
    static var selectedVoice: AVSpeechSynthesisVoice? {
        if let id = UserDefaults.standard.string(forKey: voiceKey), !id.isEmpty,
           let voice = AVSpeechSynthesisVoice(identifier: id) {
            return voice
        }
        return bestVoice
    }

    /// Every English voice on the phone, best quality first.
    static var englishVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") && !$0.voiceTraits.contains(.isNoveltyVoice) }
            .sorted {
                if $0.quality.rawValue != $1.quality.rawValue { return $0.quality.rawValue > $1.quality.rawValue }
                if $0.language != $1.language { return $0.language == "en-GB" }
                return $0.name < $1.name
            }
    }

    static func label(for voice: AVSpeechSynthesisVoice) -> String {
        let region: String
        switch voice.language {
        case "en-GB": region = "UK"
        case "en-US": region = "US"
        case "en-AU": region = "Australia"
        case "en-IE": region = "Ireland"
        case "en-ZA": region = "South Africa"
        case "en-IN": region = "India"
        default: region = Locale.current.localizedString(forIdentifier: voice.language) ?? voice.language
        }
        let quality: String
        switch voice.quality {
        case .premium: quality = " · Premium"
        case .enhanced: quality = " · Enhanced"
        default: quality = ""
        }
        return "\(voice.name) · \(region)\(quality)"
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
