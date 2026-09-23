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

    /**
     The site's own voice list is Vietnamese-only, because the site reads Chinese
     novels as Sino-Vietnamese. This app displays the same novels in Chinese, and
     a Vietnamese voice reading Chinese characters produces nothing usable, so
     the list has to cover both scripts.
     */
    private static let voiceLanguages = ["vi", "zh"]

    func availableVoices() -> [VoiceInfo] {
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { voice in
                let language = voice.language.lowercased()
                return NativeSpeech.voiceLanguages.contains { language.hasPrefix($0) }
            }
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

    /// The language the text itself is written in, as far as one can tell from
    /// its code points. CJK wins because that is what this reader shows.
    private static func scriptLanguage(for text: String) -> String {
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if (0x3040...0x30FF).contains(value)      // kana
                || (0x3400...0x4DBF).contains(value)  // CJK ext A
                || (0x4E00...0x9FFF).contains(value)  // CJK unified
                || (0xF900...0xFAFF).contains(value)  // compatibility ideographs
                || (0x20000...0x2FA1F).contains(value) {
                return "zh-CN"
            }
        }
        return "vi-VN"
    }

    /// A requested voice is honoured only when it can actually pronounce the
    /// text: the setting stores one identifier, but the reader switches between
    /// Chinese chapters and Vietnamese UI strings.
    private func voice(for identifier: String?, text: String) -> AVSpeechSynthesisVoice? {
        let language = NativeSpeech.scriptLanguage(for: text)
        let prefix = String(language.prefix(2))
        if let identifier = identifier, !identifier.isEmpty,
           let resolved = AVSpeechSynthesisVoice(identifier: identifier),
           resolved.language.lowercased().hasPrefix(prefix) {
            return resolved
        }
        if let matched = AVSpeechSynthesisVoice(language: language) {
            return matched
        }
        if let fallback = AVSpeechSynthesisVoice(language: "vi-VN") {
            return fallback
        }
        return AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
    }

    // MARK: - Synthesis to WAV

    /**
     AVSpeechSynthesizer.write() hands back an immediately-empty buffer in
     several field situations: the app's audio session was never activated; the
     utterance's voice cannot be resolved for buffer writing; or the synthesizer
     shares the app's session, which the reader's own WebAudio graph has already
     reconfigured.

     Rather than guess which one applies on a given device, walk a short list of
     configurations and keep the first that produces samples. Every attempt is
     traced into the on-device diagnostic panel, so a total failure is
     diagnosable without another blind build.
     */
    private struct Attempt {
        let usesApplicationAudioSession: Bool
        let useRequestedVoice: Bool
        let label: String
    }

    private static let attempts: [Attempt] = [
        Attempt(usesApplicationAudioSession: false, useRequestedVoice: true, label: "own-session+voice"),
        Attempt(usesApplicationAudioSession: false, useRequestedVoice: false, label: "own-session+script-default"),
        Attempt(usesApplicationAudioSession: true, useRequestedVoice: true, label: "app-session+voice")
    ]

    func synthesize(text: String,
                    identifier: String?,
                    rate: Double,
                    pitch: Double,
                    trace: @escaping (String) -> Void,
                    completion: @escaping (Result<Data, Error>) -> Void) {

        guard !text.isEmpty else {
            completion(.failure(NativeSpeech.error("empty text")))
            return
        }

        DispatchQueue.main.async {
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
                try session.setActive(true)
                trace("audio session active (playback/default/mixWithOthers)")
            } catch {
                trace("audio session setup failed: \(error.localizedDescription)")
            }
            self.run(text: text,
                     identifier: identifier,
                     rate: rate,
                     pitch: pitch,
                     attemptIndex: 0,
                     trace: trace,
                     completion: completion)
        }
    }

    private func run(text: String,
                     identifier: String?,
                     rate: Double,
                     pitch: Double,
                     attemptIndex: Int,
                     trace: @escaping (String) -> Void,
                     completion: @escaping (Result<Data, Error>) -> Void) {

        guard attemptIndex < NativeSpeech.attempts.count else {
            completion(.failure(NativeSpeech.error(
                "no audio in any of the \(NativeSpeech.attempts.count) synthesis configurations")))
            return
        }

        let attempt = NativeSpeech.attempts[attemptIndex]
        let synthesizer = AVSpeechSynthesizer()
        synthesizer.usesApplicationAudioSession = attempt.usesApplicationAudioSession

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = attempt.useRequestedVoice
            ? self.voice(for: identifier, text: text)
            : AVSpeechSynthesisVoice(language: NativeSpeech.scriptLanguage(for: text))
        utterance.rate = NativeSpeech.utteranceRate(fromSiteRate: rate)
        utterance.pitchMultiplier = NativeSpeech.utterancePitch(fromSitePitch: pitch)
        utterance.volume = 1.0

        trace("attempt \(attemptIndex + 1)/\(NativeSpeech.attempts.count) [\(attempt.label)]"
            + " voice=\(utterance.voice?.identifier ?? "nil")")

        let key = UUID().uuidString
        self.writers[key] = synthesizer

        let accumulator = PcmAccumulator()
        let lock = NSLock()
        var finished = false

        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if finished { return false }
            finished = true
            return true
        }

        func succeed(_ data: Data) {
            guard claim() else { return }
            DispatchQueue.main.async {
                self.writers.removeValue(forKey: key)
                trace("attempt \(attemptIndex + 1) ok: \(data.count) bytes")
                completion(.success(data))
            }
        }

        func retry(_ reason: String) {
            guard claim() else { return }
            DispatchQueue.main.async {
                self.writers.removeValue(forKey: key)
                trace("attempt \(attemptIndex + 1) produced nothing (\(reason))")
                self.run(text: text,
                         identifier: identifier,
                         rate: rate,
                         pitch: pitch,
                         attemptIndex: attemptIndex + 1,
                         trace: trace,
                         completion: completion)
            }
        }

        synthesizer.write(utterance) { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            if pcm.frameLength == 0 {
                let taken = accumulator.take()
                if taken.samples.isEmpty {
                    retry("\(taken.buffers) buffer callback(s), all empty")
                    return
                }
                let wav = NativeSpeech.wavContainer(samples: taken.samples,
                                                    sampleRate: taken.sampleRate,
                                                    channels: taken.channels)
                succeed(wav)
                return
            }
            accumulator.append(pcm)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            lock.lock()
            let done = finished
            lock.unlock()
            guard !done else { return }
            synthesizer.stopSpeaking(at: .immediate)
            retry("timed out after 30s")
        }
    }

    // MARK: - Direct playback

    func speakDirectly(text: String, identifier: String?, rate: Double, pitch: Double) {
        DispatchQueue.main.async {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .default, options: [.duckOthers])
            try? session.setActive(true)

            let synthesizer = AVSpeechSynthesizer()
            synthesizer.delegate = self
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = self.voice(for: identifier, text: text)
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
        // One allocation for the header plus the whole sample block: the sample
        // append below is the largest write in the app (a long sentence is
        // hundreds of KB) and growing into it one reallocation at a time is
        // pure overhead.
        data.reserveCapacity(44 + samples.count * 2)
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
            // Straight from the sample buffer into the Data. The previous
            // `Data(bytes:count:)` built a full temporary copy of the sentence and
            // then appended it, so this write cost two passes over the samples
            // instead of one.
            samples.withUnsafeBytes { raw in
                data.append(contentsOf: raw)
            }
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
        private var buffers: Int = 0

        func append(_ buffer: AVAudioPCMBuffer) {
            let format = buffer.format
            let frames = Int(buffer.frameLength)
            let channels = Int(format.channelCount)
            guard frames > 0, channels > 0 else { return }

            lock.lock()
            defer { lock.unlock() }
            buffers += 1
            if format.sampleRate > 0 { rate = format.sampleRate }
            channelCount = channels

            // Nothing to convert if the buffer carries none of the three layouts
            // -- and the previous version appended nothing in that case either,
            // so the array must not grow here.
            guard buffer.floatChannelData != nil
                || buffer.int16ChannelData != nil
                || buffer.int32ChannelData != nil else { return }

            // One buffer of exactly the right size, filled through a raw pointer,
            // then appended in a single bulk copy. The old code called `append`
            // once per sample -- a few thousand capacity checks and exclusivity
            // accesses per callback, and tens of thousands across a sentence.
            let total = frames * channels
            var chunk = [Int16](repeating: 0, count: total)
            chunk.withUnsafeMutableBufferPointer { out in
                guard let target = out.baseAddress else { return }
                if format.isInterleaved {
                    if let floatData = buffer.floatChannelData {
                        let source = floatData[0]
                        for index in 0..<total {
                            target[index] = NativeSpeech.int16(fromFloat: source[index])
                        }
                    } else if let int16Data = buffer.int16ChannelData {
                        target.update(from: int16Data[0], count: total)
                    } else if let int32Data = buffer.int32ChannelData {
                        let source = int32Data[0]
                        for index in 0..<total {
                            target[index] = Int16(clamping: source[index] >> 16)
                        }
                    }
                    return
                }
                var offset = 0
                if let floatData = buffer.floatChannelData {
                    for channel in 0..<channels {
                        let source = floatData[channel]
                        for index in 0..<frames {
                            target[offset + index] = NativeSpeech.int16(fromFloat: source[index])
                        }
                        offset += frames
                    }
                } else if let int16Data = buffer.int16ChannelData {
                    for channel in 0..<channels {
                        target.advanced(by: offset).update(from: int16Data[channel], count: frames)
                        offset += frames
                    }
                } else if let int32Data = buffer.int32ChannelData {
                    for channel in 0..<channels {
                        let source = int32Data[channel]
                        for index in 0..<frames {
                            target[offset + index] = Int16(clamping: source[index] >> 16)
                        }
                        offset += frames
                    }
                }
            }
            samples.append(contentsOf: chunk)
        }

        /// Hands the collected samples over and leaves the accumulator empty.
        ///
        /// Not a copy-avoidance trick: returning the array was already an O(1)
        /// copy-on-write retain, and clearing the property does not copy either.
        /// The point is that the accumulator stops holding the sentence once it
        /// has been handed off, so a long chapter's samples are not kept alive
        /// twice while the WAV is being written.
        func take() -> (samples: [Int16], sampleRate: Double, channels: Int, buffers: Int) {
            lock.lock()
            defer { lock.unlock() }
            let collected = samples
            samples = []
            return (collected, rate, channelCount, buffers)
        }
    }
}
