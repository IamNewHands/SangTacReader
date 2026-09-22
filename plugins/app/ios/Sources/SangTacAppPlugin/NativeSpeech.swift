import Foundation
import AVFoundation

/**
 Offline text-to-speech for the site's reader, backed by AVSpeechSynthesizer.

 Why this exists: the site hands Android a native engine as the first entry of
 app.tts.engineList() ("Android TextToSpeech" / value "google") and hands iOS
 only network providers (Bing / Zalo / FPT / Viettel / Sáng Tác Việt). There was
 no on-device option on iOS at all.

 The provider contract in /stv.tts.js is:

     props                          -> settings UI descriptors
     async speak(text, options)     -> Blob of audio
     async getVoices()              -> [{name, value, gender}]

 ttsEngine.decodeAudio() runs the Blob through AudioContext.decodeAudioData(),
 so the Blob has to be a real container. AVSpeechSynthesizer.write(
 _:toBufferCallback:) hands us raw PCM (iOS 13+), so we assemble a 16-bit PCM
 WAV here and let the JS side turn the base64 payload back into a Blob.

 `speak` (direct playback) is implemented too, because the Cordova plugin we
 stand in for exposes it; the site itself only calls speakToFile.
 */
final class NativeSpeech: NSObject, AVSpeechSynthesizerDelegate {

    static let shared = NativeSpeech()

    /// Synthesizers are retained here for the whole synthesis: dropping the last
    /// reference mid-flight stops the buffer callbacks.
    private var writers: [String: AVSpeechSynthesizer] = [:]
    private var players: [ObjectIdentifier: AVSpeechSynthesizer] = [:]

    struct VoiceInfo {
        let identifier: String
        let name: String
        let language: String
        /// Mirrors AVSpeechSynthesisVoiceGender: 0 unspecified, 1 male, 2 female.
        let gender: Int
    }

    private override init() {
        super.init()
    }

    // MARK: - Voices

    func availableVoices() -> [VoiceInfo] {
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.lowercased().hasPrefix("vi") }
            .map { voice in
                let gender: Int
                switch voice.gender {
                case .male: gender = 1
                case .female: gender = 2
                default: gender = 0
                }
                return VoiceInfo(identifier: voice.identifier,
                                 name: voice.name,
                                 language: voice.language,
                                 gender: gender)
            }
    }

    private func voice(for identifier: String?) -> AVSpeechSynthesisVoice? {
        if let identifier = identifier, !identifier.isEmpty,
           let resolved = AVSpeechSynthesisVoice(identifier: identifier) {
            return resolved
        }
        if let vietnamese = AVSpeechSynthesisVoice(language: "vi-VN") {
            return vietnamese
        }
        return AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
    }

    // MARK: - Synthesis to WAV

    func synthesize(text: String,
                    identifier: String?,
                    rate: Double,
                    pitch: Double,
                    completion: @escaping (Result<Data, Error>) -> Void) {

        guard !text.isEmpty else {
            completion(.failure(NativeSpeech.error("empty text")))
            return
        }

        DispatchQueue.main.async {
            // AVSpeechSynthesizer.write() is unreliable when the app has never
            // configured an audio session. `.mixWithOthers` is deliberate: the
            // reader plays the synthesised WAV through its own WebAudio graph,
            // and we must not duck or stop it.
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .spokenAudio, options: [.mixWithOthers])

            let synthesizer = AVSpeechSynthesizer()
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = self.voice(for: identifier)
            utterance.rate = NativeSpeech.utteranceRate(fromSiteRate: rate)
            utterance.pitchMultiplier = NativeSpeech.utterancePitch(fromSitePitch: pitch)
            utterance.volume = 1.0

            let key = UUID().uuidString
            self.writers[key] = synthesizer

            let accumulator = PcmAccumulator()
            let lock = NSLock()
            var finished = false

            func finish(_ result: Result<Data, Error>) {
                lock.lock()
                if finished {
                    lock.unlock()
                    return
                }
                finished = true
                lock.unlock()
                DispatchQueue.main.async {
                    self.writers.removeValue(forKey: key)
                    completion(result)
                }
            }

            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    let snapshot = accumulator.snapshot()
                    if snapshot.samples.isEmpty {
                        finish(.failure(NativeSpeech.error("speech synthesis produced no audio")))
                        return
                    }
                    let wav = NativeSpeech.wavContainer(samples: snapshot.samples,
                                                        sampleRate: snapshot.sampleRate,
                                                        channels: snapshot.channels)
                    finish(.success(wav))
                    return
                }
                accumulator.append(pcm)
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                lock.lock()
                let done = finished
                lock.unlock()
                if !done {
                    synthesizer.stopSpeaking(at: .immediate)
                    finish(.failure(NativeSpeech.error("speech synthesis timed out")))
                }
            }
        }
    }

    // MARK: - Direct playback

    func speakDirectly(text: String, identifier: String?, rate: Double, pitch: Double) {
        DispatchQueue.main.async {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])

            let synthesizer = AVSpeechSynthesizer()
            synthesizer.delegate = self
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = self.voice(for: identifier)
            utterance.rate = NativeSpeech.utteranceRate(fromSiteRate: rate)
            utterance.pitchMultiplier = NativeSpeech.utterancePitch(fromSitePitch: pitch)
            self.players[ObjectIdentifier(synthesizer)] = synthesizer
            synthesizer.speak(utterance)
        }
    }

    func stopAll() {
        DispatchQueue.main.async {
            for (_, synthesizer) in self.writers {
                synthesizer.stopSpeaking(at: .immediate)
            }
            for (_, synthesizer) in self.players {
                synthesizer.stopSpeaking(at: .immediate)
            }
            self.writers.removeAll()
            self.players.removeAll()
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        // Delegate callbacks are not guaranteed to be on the main thread, and
        // stopAll() may be iterating `players` right now.
        DispatchQueue.main.async {
            self.players.removeValue(forKey: ObjectIdentifier(synthesizer))
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.players.removeValue(forKey: ObjectIdentifier(synthesizer))
        }
    }

    // MARK: - Parameter mapping

    /// The site's provider rate is a plain multiplier around 1.0 (the Android
    /// provider hands it to TextToSpeech.setSpeechRate). AVSpeechUtterance.rate
    /// lives in 0.0...1.0 with AVSpeechUtteranceDefaultSpeechRate == 0.5.
    private static func utteranceRate(fromSiteRate rate: Double) -> Float {
        let scaled = 0.5 * (rate.isFinite ? rate : 1.0)
        let lower = Double(AVSpeechUtteranceMinimumSpeechRate)
        let upper = Double(AVSpeechUtteranceMaximumSpeechRate)
        return Float(min(max(scaled, lower), upper))
    }

    private static func utterancePitch(fromSitePitch pitch: Double) -> Float {
        let value = pitch.isFinite ? pitch : 1.0
        return Float(min(max(value, 0.5), 2.0))
    }

    private static func error(_ message: String) -> NSError {
        return NSError(domain: "SangTacTTS", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: - WAV assembly

    private static func int16(fromFloat value: Float) -> Int16 {
        if !value.isFinite { return 0 }
        let clamped = min(max(value, -1.0), 1.0)
        return Int16(clamped * 32767.0)
    }

    private static func wavContainer(samples: [Int16], sampleRate: Double, channels: Int) -> Data {
        let bitsPerSample = 16
        let channelCount = max(channels, 1)
        let rate = sampleRate > 0 ? UInt32(sampleRate) : 22050
        let byteRate = rate * UInt32(channelCount) * UInt32(bitsPerSample / 8)
        let blockAlign = UInt16(channelCount * bitsPerSample / 8)
        let dataBytes = UInt32(samples.count * 2)

        var data = Data()
        func appendUInt32(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        func appendUInt16(_ value: UInt16) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }

        data.append(contentsOf: Array("RIFF".utf8))
        appendUInt32(36 + dataBytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        appendUInt32(16)
        appendUInt16(1)
        appendUInt16(UInt16(channelCount))
        appendUInt32(rate)
        appendUInt32(byteRate)
        appendUInt16(blockAlign)
        appendUInt16(UInt16(bitsPerSample))
        data.append(contentsOf: Array("data".utf8))
        appendUInt32(dataBytes)
        if !samples.isEmpty {
            data.append(Data(bytes: samples, count: samples.count * 2))
        }
        return data
    }

    /// Collects the PCM the synthesizer emits, converting whatever sample
    /// format the installed voice uses into interleaved 16-bit samples.
    private final class PcmAccumulator {
        private let lock = NSLock()
        private var samples: [Int16] = []
        private var rate: Double = 22050
        private var channelCount: Int = 1

        func append(_ buffer: AVAudioPCMBuffer) {
            let format = buffer.format
            let frames = Int(buffer.frameLength)
            let channels = Int(format.channelCount)
            guard frames > 0, channels > 0 else { return }

            lock.lock()
            defer { lock.unlock() }
            if format.sampleRate > 0 { rate = format.sampleRate }
            channelCount = channels

            if format.isInterleaved {
                let total = frames * channels
                if let floatData = buffer.floatChannelData {
                    let pointer = floatData[0]
                    for index in 0..<total { samples.append(NativeSpeech.int16(fromFloat: pointer[index])) }
                } else if let int16Data = buffer.int16ChannelData {
                    let pointer = int16Data[0]
                    for index in 0..<total { samples.append(pointer[index]) }
                } else if let int32Data = buffer.int32ChannelData {
                    let pointer = int32Data[0]
                    for index in 0..<total { samples.append(Int16(clamping: pointer[index] >> 16)) }
                }
                return
            }

            if let floatData = buffer.floatChannelData {
                for channel in 0..<channels {
                    let pointer = floatData[channel]
                    for index in 0..<frames { samples.append(NativeSpeech.int16(fromFloat: pointer[index])) }
                }
            } else if let int16Data = buffer.int16ChannelData {
                for channel in 0..<channels {
                    let pointer = int16Data[channel]
                    for index in 0..<frames { samples.append(pointer[index]) }
                }
            } else if let int32Data = buffer.int32ChannelData {
                for channel in 0..<channels {
                    let pointer = int32Data[channel]
                    for index in 0..<frames { samples.append(Int16(clamping: pointer[index] >> 16)) }
                }
            }
        }

        func snapshot() -> (samples: [Int16], sampleRate: Double, channels: Int) {
            lock.lock()
            defer { lock.unlock() }
            return (samples, rate, channelCount)
        }
    }
}
