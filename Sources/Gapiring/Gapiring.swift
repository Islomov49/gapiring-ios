import AVFoundation
import Foundation

/// Gapiring Edge on the device: Uzbek text-to-speech with the model inside the package, no network.
///
///     let tts = try Gapiring()                                 // off the main thread: loads the model
///     tts.play("Assalomu alaykum! Namuna kompaniyasining virtual yordamchisiman, sizga qanday yordam bera olaman?", voice: "f1", role: "assistant", manner: "warm")
///
/// `play` returns at once and speaks on a background queue; `stream` and `speak` run on the calling thread.
public final class Gapiring {
    public static let version = "0.1.2"
    public let sampleRate: Int

    private let engine: Engine
    private let queue = DispatchQueue(label: "uz.gapi.gapiring")
    private let lock = NSLock()
    private var generation = 0
    private lazy var audio = AVAudioEngine()
    private lazy var player = AVAudioPlayerNode()
    private var wired = false

    /// The model that ships inside the package.
    public convenience init(threads: Int = 2) throws {
        guard let dir = Bundle.module.url(forResource: "Model", withExtension: nil) else {
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

    /// 24 kHz mono float chunks as they are made; return false from `onChunk` to stop. Blocks: call off the main thread.
    public func stream(_ text: String, voice: String = "f1", role: String = "assistant", manner: String = "neutral", seed: UInt32 = 1,
                       onChunk: ([Float]) -> Bool) throws {
        try engine.stream(text, voice: voice, role: role, manner: manner, seed: seed, onChunk: onChunk)
    }

    /// The whole line as one array. Blocks: call off the main thread.
    public func speak(_ text: String, voice: String = "f1", role: String = "assistant", manner: String = "neutral", seed: UInt32 = 1) throws -> [Float] {
        var out: [Float] = []
        try stream(text, voice: voice, role: role, manner: manner, seed: seed) { out += $0; return true }
        return out
    }

    /// The token ids the model reads for a line.
    public func tokens(_ text: String, role: String = "assistant", manner: String = "neutral") throws -> [Int] {
        try engine.tokens(text, role: role, manner: manner)
    }

    /// Speaks the line through the device's audio output as it is made. A new call waits for the line before it;
    /// `stop()` drops what is playing and what waits. `completion` gets the error, if any, on the background queue.
    public func play(_ text: String, voice: String = "f1", role: String = "assistant", manner: String = "neutral", seed: UInt32 = 1,
                     completion: ((Error?) -> Void)? = nil) {
        let mine = current
        queue.async { [self] in
            guard mine == current else { completion?(nil); return }
            do {
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
                try engine.stream(text, voice: voice, role: role, manner: manner, seed: seed) { chunk in
                    guard mine == current, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.count)) else { return false }
                    buffer.frameLength = AVAudioFrameCount(chunk.count)
                    chunk.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: chunk.count) }
                    done.enter()
                    player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in done.leave() }
                    return true
                }
                done.wait()          // the line has been heard (or stop() cleared the player)
                completion?(nil)
            } catch {
                completion?(error)
            }
        }
    }

    /// Stops the line that is playing and drops the ones that wait.
    public func stop() {
        lock.lock(); generation += 1; lock.unlock()
        if wired { player.stop() }
    }
}
