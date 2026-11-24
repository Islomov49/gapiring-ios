import Foundation
import OnnxRuntimeBindings

/// The generation loop over the graphs of a model folder: bundle.json, tokenizer.json, init_states.onnx,
/// text_conditioner / flow_lm_main / flow_lm_flow / mimi_decoder (_int8.onnx) and voices/<voice>.bin.
/// One line at a time (not thread-safe).
final class Engine {
    private struct State { let input: String; let output: String }

    private let dir: URL
    private let env: ORTEnv
    private let textCond: ORTSession, main: ORTSession, flow: ORTSession, decoder: ORTSession
    private let meta: [String: Any]
    private let tokenizer: Tokenizer
    private let lmStates: [State], mimiStates: [State]
    private let lmStart: [ORTValue], mimiStart: [ORTValue]
    private let emptySequence: ORTValue, emptyText: ORTValue
    private var voiceStates: [String: [ORTValue]] = [:]
    private let ldim: Int, dim: Int
    let sampleRate: Int

    init(dir: URL, threads: Int) throws {
        self.dir = dir
        let env = try ORTEnv(loggingLevel: .warning)   // a local: the nested func below must not capture self yet
        self.env = env
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(Int32(threads))
        try options.setGraphOptimizationLevel(.all)
        func session(_ file: String) throws -> ORTSession {
            try ORTSession(env: env, modelPath: dir.appendingPathComponent(file).path, sessionOptions: options)
        }
        textCond = try session("text_conditioner_int8.onnx")
        main = try session("flow_lm_main_int8.onnx")
        flow = try session("flow_lm_flow_int8.onnx")
        decoder = try session("mimi_decoder_int8.onnx")
        guard let m = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("bundle.json"))) as? [String: Any] else {
            throw GapiringError.model("bundle.json: not an object")
        }
        meta = m
        tokenizer = try Tokenizer(json: Data(contentsOf: dir.appendingPathComponent("tokenizer.json")))
        func manifest(_ key: String) throws -> [State] {
            guard let rows = m[key] as? [[String: Any]] else { throw GapiringError.model("bundle.json: \(key)") }
            return try rows.map {
                guard let i = $0["input_name"] as? String, let o = $0["output_name"] as? String else { throw GapiringError.model("bundle.json: \(key) names") }
                return State(input: i, output: o)
            }
        }
        lmStates = try manifest("flow_lm_state_manifest")
        mimiStates = try manifest("mimi_state_manifest")
        ldim = try Engine.number(m, "latent_dim").intValue
        dim = try Engine.number(m, "conditioning_dim").intValue
        sampleRate = try Engine.number(m, "sample_rate").intValue

        // The start states (bool and zero-length tensors among them) come out of a tiny graph, init_states.onnx: the
        // Objective-C API cannot build a bool tensor. The same values serve every line: a run never changes its inputs.
        let start = try session("init_states.onnx")
        let names = Set(lmStates.map { "lm_" + $0.input } + mimiStates.map { "mimi_" + $0.input } + ["empty_sequence", "empty_text"])
        let out = try start.run(withInputs: ["seed": try Engine.floats([0], [1])], outputNames: names, runOptions: nil)
        func take(_ name: String) throws -> ORTValue {
            guard let v = out[name] else { throw GapiringError.model("init_states.onnx: no output \(name)") }
            return v
        }
        lmStart = try lmStates.map { try take("lm_" + $0.input) }
        mimiStart = try mimiStates.map { try take("mimi_" + $0.input) }
        emptySequence = try take("empty_sequence")
        emptyText = try take("empty_text")
    }

    private static func number(_ m: [String: Any], _ key: String) throws -> NSNumber {
        guard let n = m[key] as? NSNumber else { throw GapiringError.model("bundle.json: \(key)") }
        return n
    }

    private static func floats(_ data: [Float], _ shape: [Int]) throws -> ORTValue {
        let bytes = NSMutableData(bytes: data, length: data.count * MemoryLayout<Float>.stride)
        return try ORTValue(tensorData: bytes, elementType: .float, shape: shape.map { NSNumber(value: $0) })
    }

    private static func read(_ value: ORTValue) throws -> [Float] {
        let data = try value.tensorData() as Data
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// One step of the backbone: "conditioning", "eos_logit" and the next states.
    private func step(_ sequence: ORTValue, _ text: ORTValue, _ states: [ORTValue]) throws -> (cond: ORTValue, eos: Float, states: [ORTValue]) {
        var feed: [String: ORTValue] = ["sequence": sequence, "text_embeddings": text]
        for (i, s) in lmStates.enumerated() { feed[s.input] = states[i] }
        let out = try main.run(withInputs: feed, outputNames: Set(["conditioning", "eos_logit"] + lmStates.map { $0.output }), runOptions: nil)
        guard let cond = out["conditioning"], let eos = out["eos_logit"] else { throw GapiringError.model("flow_lm_main: outputs") }
        let next = try lmStates.map { s -> ORTValue in
            guard let v = out[s.output] else { throw GapiringError.model("flow_lm_main: no \(s.output)") }
            return v
        }
        return (cond, try Engine.read(eos)[0], next)
    }

    private func voice(_ voice: String) throws -> [ORTValue] {
        if let s = voiceStates[voice] { return s }
        guard let shapes = meta["voice_shapes"] as? [String: [NSNumber]], let shape = shapes[voice] else {
            throw GapiringError.unknown("voice \(voice): choose from \(Speech.voices)")
        }
        let data = try Data(contentsOf: dir.appendingPathComponent("voices/\(voice).bin"))   // float32, little-endian
        let emb = try ORTValue(tensorData: NSMutableData(data: data), elementType: .float, shape: shape)
        let states = try step(emptySequence, emb, lmStart).states
        voiceStates[voice] = states
        return states
    }

    func tokens(_ text: String, role: String, manner: String) throws -> [Int] {
        tokenizer.encode(try Speech.full(text, role: role, manner: manner))
    }

    /// Calls `onChunk` with 24 kHz mono float audio as it is made: the first chunk after one frame (80 ms), then every
    /// `chunkFrames` frames. Return false from `onChunk` to stop the line. Returns false when `onChunk` stopped it.
    @discardableResult
    func stream(_ text: String, voice v: String, role: String, manner: String, seed: UInt32, chunkFrames: Int = 3,
                onChunk: ([Float]) -> Bool) throws -> Bool {
        var rand = Mulberry32(seed)
        let std = try Engine.number(meta, "temperature").doubleValue.squareRoot()
        let ids = try tokens(text, role: role, manner: manner)
        let perSecond = try Engine.number(meta, "tokens_per_second_estimate").doubleValue
        let padding = try Engine.number(meta, "gen_seconds_padding").doubleValue
        let maxGen = Int((Double(ids.count) / perSecond + padding) * (try Engine.number(meta, "frame_rate").doubleValue))
        let after = (Speech.words(text) <= 4 ? 3 : 1) + 2
        let eosThreshold = try Engine.number(meta, "eos_threshold").floatValue
        let minFrames = try Engine.number(meta, "min_frames_before_eos").intValue
        let fade = try Engine.number(meta, "fade_in_samples").intValue

        let idData = NSMutableData(bytes: ids.map { Int64($0) }, length: ids.count * MemoryLayout<Int64>.stride)
        let tokenIds = try ORTValue(tensorData: idData, elementType: .int64, shape: [1, NSNumber(value: ids.count)])
        guard let emb = try textCond.run(withInputs: ["token_ids": tokenIds], outputNames: ["text_embeddings"], runOptions: nil)["text_embeddings"] else {
            throw GapiringError.model("text_conditioner: no text_embeddings")
        }
        var lm = try step(emptySequence, emb, try voice(v))
        var mimi = mimiStart
        let s0 = try Engine.floats([0], [1, 1]), s1 = try Engine.floats([1], [1, 1])
        var latent = [Float](repeating: .nan, count: ldim)
        var pending: [[Float]] = []
        var eosStep = -1
        var first = true

        func decode() throws -> [Float] {
            var feed: [String: ORTValue] = ["latent": try Engine.floats(pending.flatMap { $0 }, [1, pending.count, ldim])]
            for (i, s) in mimiStates.enumerated() { feed[s.input] = mimi[i] }
            let out = try decoder.run(withInputs: feed, outputNames: Set(["audio"] + mimiStates.map { $0.output }), runOptions: nil)
            mimi = try mimiStates.map { s -> ORTValue in
                guard let value = out[s.output] else { throw GapiringError.model("mimi_decoder: no \(s.output)") }
                return value
            }
            guard let a = out["audio"] else { throw GapiringError.model("mimi_decoder: no audio") }
            var audio = try Engine.read(a)
            if first {
                for i in 0..<min(fade, audio.count) { audio[i] *= Float(i) / Float(fade) }
                first = false
            }
            pending.removeAll(keepingCapacity: true)
            return audio
        }

        var go = true
        var n = 0
        while go && n < maxGen {
            lm = try step(try Engine.floats(latent, [1, 1, ldim]), emptyText, lm.states)
            if lm.eos > eosThreshold && eosStep == -1 && n >= minFrames { eosStep = n }
            if eosStep != -1 && n >= eosStep + after { break }
            var noise = [Float](repeating: 0, count: ldim)
            var i = 0
            while i < ldim {   // Box-Muller pairs
                let u = max(rand.next(), 1e-12), w = rand.next()
                let r = (-2 * log(u)).squareRoot() * std
                noise[i] = Float(r * cos(2 * Double.pi * w))
                if i + 1 < ldim { noise[i + 1] = Float(r * sin(2 * Double.pi * w)) }
                i += 2
            }
            guard let dirValue = try flow.run(withInputs: ["c": lm.cond, "s": s0, "t": s1, "x": try Engine.floats(noise, [1, ldim])],
                                              outputNames: ["flow_dir"], runOptions: nil)["flow_dir"] else {
                throw GapiringError.model("flow_lm_flow: no flow_dir")
            }
            let dir = try Engine.read(dirValue)
            latent = (0..<ldim).map { noise[$0] + dir[$0] }
            pending.append(latent)
            if first || pending.count >= chunkFrames { go = onChunk(try decode()) }
            n += 1
        }
        if go && !pending.isEmpty { go = onChunk(try decode()) }
        return go
    }
}
