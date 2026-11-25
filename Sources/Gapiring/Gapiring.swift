import AVFoundation
import Foundation

/// Gapiring Edge on the device: Uzbek text-to-speech with the model inside the package, no network.
///
///     let tts = try Gapiring()                                 // off the main thread: loads the model
///     tts.play("Assalomu alaykum! Namuna kompaniyasining virtual yordamchisiman, sizga qanday yordam bera olaman?", voice: "f1", role: "assistant", manner: "warm")
///
/// `play` returns at once and speaks on a background queue; `stream` and `speak` run on the calling thread. A text of
/// any length is spoken piece by piece (`Speech.splitText`) with `pause` seconds of silence between the pieces.
///
/// The manner is optional (the narrator reads a book, every other role is neutral); `pace` ("slow", "fast"), `serious`
/// and `hesitant` are optional marks, one at a time, for the roles and manners in `Speech.paceManners` and
/// `Speech.tags`. A combination outside them throws before any audio is made. Code written for 0.1 runs unchanged.
public final class Gapiring {
    public static let version = "0.2.0"
    public let sampleRate: Int

    private let engine: Engine
    private let queue = DispatchQueue(label: "uz.gapi.gapiring")
    private let lock = NSLock()
    private var generation = 0
    private lazy var audio = AVAudioEngine()
    private lazy var player = AVAudioPlayerNode()
    private var wired = false

    /// The model folder inside the package (Sources/Gapiring/Model).
    static var packagedModel: URL? { Bundle.module.url(forResource: "Model", withExtension: nil) }

    /// The model that ships inside the package.
    public convenience init(threads: Int = 2) throws {
        guard let dir = Gapiring.packagedModel else {
            throw GapiringError.model("the Model folder is not in the package's resources")
        }
        try self.init(modelDirectory: dir, threads: threads)
    }

    /// A model folder on disk (bundle.json, tokenizer.json, init_states.onnx, the four graphs, voices/).
    public init(modelDirectory: URL, threads: Int = 2) throws {
        engine = try Engine(dir: modelDirectory, threads: threads)
        sampleRate = engine.sampleRate
    }

    private var current: Int { lock.lock(); defer { lock.unlock() }; return generation }

    /// 24 kHz mono float chunks as they are made; return false from `onChunk` to stop the whole text. A longer text is
    /// spoken piece by piece (`Speech.splitText`; the narrator's pieces are up to 280 code points), each piece with the
    /// same `seed`, with `pause` seconds of silence (zeros) between the pieces. Blocks: call off the main thread.
    public func stream(_ text: String, voice: String = "f1", role: String = "assistant", manner: String? = nil, seed: UInt32 = 1,
                       pause: Double = 0.25, pace: String? = nil, serious: Bool = false, hesitant: Bool = false,
                       onChunk: ([Float]) -> Bool) throws {
        let tags = try Speech.tags(role: role, manner: manner, pace: pace, serious: serious, hesitant: hesitant)
        let silence = [Float](repeating: 0, count: Int((max(pause, 0) * Double(sampleRate)).rounded()))
        for (i, piece) in Speech.pieces(text, role: role).enumerated() {
            if i > 0 && !silence.isEmpty && !onChunk(silence) { return }
            guard try engine.stream(piece, voice: voice, tags: tags, seed: seed, onChunk: onChunk) else { return }
        }
    }

    /// The whole text as one array. Blocks: call off the main thread.
    public func speak(_ text: String, voice: String = "f1", role: String = "assistant", manner: String? = nil, seed: UInt32 = 1,
                      pause: Double = 0.25, pace: String? = nil, serious: Bool = false, hesitant: Bool = false) throws -> [Float] {
        var out: [Float] = []
        try stream(text, voice: voice, role: role, manner: manner, seed: seed, pause: pause, pace: pace, serious: serious,
                   hesitant: hesitant) { out += $0; return true }
        return out
    }

    /// The token ids the model reads for a line (one piece of `Speech.splitText`).
    public func tokens(_ text: String, role: String = "assistant", manner: String? = nil, pace: String? = nil,
                       serious: Bool = false, hesitant: Bool = false) throws -> [Int] {
        engine.tokens(text, tags: try Speech.tags(role: role, manner: manner, pace: pace, serious: serious, hesitant: hesitant))
    }

    /// Speaks the text through the device's audio output as it is made. A new call waits for the text before it;
    /// `stop()` drops what is playing and what waits. `completion` gets the error, if any, on the background queue.
    public func play(_ text: String, voice: String = "f1", role: String = "assistant", manner: String? = nil, seed: UInt32 = 1,
                     pause: Double = 0.25, pace: String? = nil, serious: Bool = false, hesitant: Bool = false,
                     completion: ((Error?) -> Void)? = nil) {
        let mine = current
        queue.async { [self] in
            guard mine == current else { completion?(nil); return }
            do {
                _ = try Speech.tags(role: role, manner: manner, pace: pace, serious: serious, hesitant: hesitant)   // before the audio session
                let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1)!
                if !wired {
                    #if os(iOS)
                    try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
                    try AVAudioSession.sharedInstance().setActive(true)
                    #endif
                    audio.attach(player)
                    audio.connect(player, to: audio.mainMixerNode, format: format)
                    wired = true
                }
                if !audio.isRunning { try audio.start() }
                player.play()
                let done = DispatchGroup()
                try stream(text, voice: voice, role: role, manner: manner, seed: seed, pause: pause, pace: pace, serious: serious,
                           hesitant: hesitant) { chunk in
                    guard mine == current, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.count)) else { return false }
                    buffer.frameLength = AVAudioFrameCount(chunk.count)
                    chunk.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: chunk.count) }
                    done.enter()
                    player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in done.leave() }
                    return true
                }
                done.wait()          // the text has been heard (or stop() cleared the player)
                completion?(nil)
            } catch {
                completion?(error)
            }
        }
    }

    /// Stops the text that is playing and drops the ones that wait.
    public func stop() {
        lock.lock(); generation += 1; lock.unlock()
        if wired { player.stop() }
    }
}
