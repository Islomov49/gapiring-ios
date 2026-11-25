import XCTest
@testable import Gapiring

/// Reference data sits in Tests/GapiringTests/Reference: public_cases.jsonl, split_cases.jsonl and speak_lines.jsonl,
/// the files every Gapiring runtime checks itself against (text-contract v2, made by the Python runtime).
final class GapiringTests: XCTestCase {
    private func modelFile(_ name: String) throws -> URL {
        try XCTUnwrap(Gapiring.packagedModel, "the Model folder is not in the package's resources").appendingPathComponent(name)
    }

    private func reference(_ name: String) throws -> [[String: Any]] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Reference/\(name)", withExtension: "jsonl"))
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    /// 16-bit WAV in the temporary folder (the path is printed) for a listen and a recogniser.
    @discardableResult
    private func wav(_ audio: [Float], _ name: String) throws -> URL {
        var wav = Data()
        func put<T>(_ v: T) { withUnsafeBytes(of: v) { wav.append(contentsOf: $0) } }
        wav.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + audio.count * 2)); wav.append(contentsOf: Array("WAVEfmt ".utf8))
        put(UInt32(16)); put(UInt16(1)); put(UInt16(1)); put(UInt32(24000)); put(UInt32(48000)); put(UInt16(2)); put(UInt16(16))
        wav.append(contentsOf: Array("data".utf8)); put(UInt32(audio.count * 2))
        for s in audio { put(Int16(max(-1, min(1, s)) * 32767)) }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try wav.write(to: out)
        print("wav", out.path)
        return out
    }

    private static let greeting = "Assalomu alaykum! Namuna kompaniyasining virtual yordamchisiman, sizga qanday yordam bera olaman?"

    /// The README's lines joined (more than 400 code points), typed with U+02BB as an Uzbek phone keyboard does.
    static let longText = [
        greeting,
        "Bugun obunani rasmiylashtirsangiz, birinchi oy uchun to'liq ellik foiz chegirma beriladi, imkoniyatni qo'ldan boy bermang.",
        "Kechasi o'g'limning isitmasi chiqqanda shifokoringiz tez yetib kelib yordam berdi, klinika jamoasiga ming rahmat, baraka topinglar!",
        "Oyimning tug'ilgan kuniga sovg'a buyurtma qilgandim, vaqtida olib kelmadinglar, rosa xafa bo'ldim to'g'risi.",
    ].joined(separator: " ").replacingOccurrences(of: "'", with: "\u{02BB}")

    /// The random generator gives the numbers of the JavaScript and Kotlin runtimes.
    func testRandom() {
        var r = Mulberry32(3)
        let want = [0.7202267837710679, 0.03866216051392257, 0.4561921926215291, 0.07492800964973867]
        for w in want { XCTAssertEqual(r.next(), w, accuracy: 0) }
    }

    /// Every reference case (368): the symbols from role, manner and mark equal `tags`, the text front equals `text`, the
    /// tokenizer gives `ids` for `full`.
    func testTextAndTokens() throws {
        let tokenizer = try Tokenizer(json: Data(contentsOf: modelFile("tokenizer.json")))
        var cases = 0, badTags = 0, badText = 0, badFull = 0, badIds = 0
        for r in try reference("public_cases") {
            cases += 1
            let raw = r["raw"] as! String, role = r["role"] as! String, manner = r["manner"] as? String
            let want = r["tags"] as! String, text = r["text"] as! String
            let full = r["full"] as! String, ids = (r["ids"] as! [NSNumber]).map { $0.intValue }
            let tags = try Speech.tags(role: role, manner: manner, pace: r["pace"] as? String,
                                       serious: r["serious"] as? Bool ?? false, hesitant: r["hesitant"] as? Bool ?? false)
            if Array(tags.unicodeScalars) != Array(want.unicodeScalars) { badTags += 1; print("TAGS", role, manner ?? "-", r) }
            if Array(Speech.pocketText(raw, tags: want).unicodeScalars) != Array(text.unicodeScalars) { badText += 1; print("TEXT", raw) }
            if Array(Speech.full(raw, tags: want).unicodeScalars) != Array(full.unicodeScalars) { badFull += 1; print("FULL", raw) }
            if tokenizer.encode(full) != ids { badIds += 1; print("IDS", full.prefix(60)) }
        }
        print("cases \(cases), tags mismatches \(badTags), text mismatches \(badText), full mismatches \(badFull), id mismatches \(badIds)")
        XCTAssertEqual(cases, 368)
        XCTAssertEqual(badTags, 0)
        XCTAssertEqual(badText, 0)
        XCTAssertEqual(badFull, 0)
        XCTAssertEqual(badIds, 0)
    }

    /// splitText cuts every reference text into the pieces of the other runtimes, scalar by scalar (165 cases, the
    /// narrator's with limit 280 and hard 340).
    func testSplitText() throws {
        var cases = 0, bad = 0, narrator = 0
        for r in try reference("split_cases") {
            cases += 1
            let text = r["text"] as! String, want = r["pieces"] as! [String]
            let limit = (r["limit"] as? NSNumber)?.intValue ?? 150, hard = (r["hard"] as? NSNumber)?.intValue ?? 240
            let got = Speech.splitText(text, limit: limit, hard: hard)
            if r["limit"] != nil {
                narrator += 1
                XCTAssertEqual(Speech.pieces(text, role: "narrator"), got, "the narrator's pieces are 280 / 340")
            }
            if got.map({ Array($0.unicodeScalars) }) != want.map({ Array($0.unicodeScalars) }) {
                bad += 1
                print("SPLIT", text.prefix(60), "got", got.count, "want", want.count)
            }
        }
        print("split cases \(cases) (\(narrator) with the narrator's size), mismatches \(bad)")
        XCTAssertEqual(cases, 165)
        XCTAssertEqual(bad, 0)
    }

    /// The manner defaults to book for the narrator and to neutral for the others; combinations outside text-contract v2
    /// throw, and `stream` throws before any audio.
    func testCombinations() throws {
        XCTAssertEqual(try Speech.tags(role: "narrator"), "\u{247A}\u{247C}")
        XCTAssertEqual(try Speech.tags(role: "operator"), "\u{2460}\u{2472}")
        XCTAssertEqual(try Speech.tags(role: "assistant"), "\u{2462}\u{2472}")
        XCTAssertEqual(try Speech.tags(role: "narrator", manner: "news", pace: "fast"), "\u{247A}\u{247E}\u{2481}")
        XCTAssertEqual(try Speech.tags(role: "narrator", manner: "article", serious: true), "\u{247A}\u{247D}\u{247B}")
        XCTAssertEqual(try Speech.tags(role: "assistant", manner: "warm", hesitant: true), "\u{2462}\u{2473}\u{2482}")
        let wrong: [(String, String?, String?, Bool, Bool)] = [
            ("narrator", "warm", nil, false, false),              // a manner the narrator does not have
            ("emotional", "angry", "slow", false, false),         // pace with emotional
            ("assistant_formal", "warm", nil, false, true),       // hesitant with assistant_formal
            ("assistant", "warm", "slow", false, true),           // two marks at once
            ("narrator", "news", "fast", true, false),            // two marks at once
            ("narrator", "news", "slow", false, false),           // slow only with article
            ("narrator", "article", "fast", false, false),        // fast only with news
            ("narrator", "book", nil, true, false),               // serious only with article or news
            ("operator", "neutral", nil, true, false),            // serious is a manner for the other roles
            ("operator", "dictation", "fast", false, false),      // not in paceManners
            ("assistant", "neutral", "medium", false, false),     // slow or fast
            ("assistant", "serious", nil, false, true),           // hesitant without serious
            ("teacher", nil, nil, false, false),                  // no such role
        ]
        for (role, manner, pace, serious, hesitant) in wrong {
            XCTAssertThrowsError(try Speech.tags(role: role, manner: manner, pace: pace, serious: serious, hesitant: hesitant),
                                 "\(role)/\(manner ?? "-") pace \(pace ?? "-") serious \(serious) hesitant \(hesitant)")
        }
        // paceManners has the shape of the other runtimes (role -> pace -> manners) and is what tags allows, no more.
        XCTAssertEqual(Speech.paceManners["narrator"], ["slow": ["article"], "fast": ["news"]])
        XCTAssertEqual(Speech.paceManners["operator"]?["slow"], ["neutral", "warm", "cheerful", "calm", "persuasive"])
        XCTAssertEqual(Speech.paceManners["assistant"]?["fast"], ["neutral", "warm", "cheerful", "calm"])
        XCTAssertEqual(Set(Speech.paceManners.keys), ["operator", "assistant", "assistant_formal", "narrator"])
        for (role, manners) in Speech.roleManners {
            for pace in ["slow", "fast"] {
                for manner in manners {
                    let allowed = Speech.paceManners[role]?[pace]?.contains(manner) == true
                    let tags = try? Speech.tags(role: role, manner: manner, pace: pace)
                    XCTAssertEqual(tags != nil, allowed, "\(role)/\(manner) pace \(pace)")
                }
            }
        }
        let tts = try Gapiring()
        var chunks = 0
        XCTAssertThrowsError(try tts.stream("Salom.", role: "narrator", manner: "warm") { _ in chunks += 1; return true })
        XCTAssertThrowsError(try tts.speak("Salom.", role: "assistant", manner: "warm", pace: "slow", hesitant: true))
        XCTAssertEqual(chunks, 0)
    }

    /// Code written for 0.1.7 runs on 0.2 as it is: the 36 role and manner pairs keep their symbols and token ids in front
    /// and speak, and the call forms of 0.1.7 compile.
    func testCode01RunsUnchanged() throws {
        let roles01 = ["operator": "\u{2460}", "assistant": "\u{2462}", "assistant_formal": "\u{2463}", "emotional": "\u{2461}"]
        let manners01: [String: String] = [
            "calm": "\u{2464}", "neutral": "\u{2472}", "warm": "\u{2473}", "cheerful": "\u{2474}", "empathetic": "\u{2475}",
            "dictation": "\u{2476}", "persuasive": "\u{2477}", "brisk": "\u{2478}", "soothing": "\u{2479}", "angry": "\u{246c}",
            "upset": "\u{246e}", "irritated": "\u{246b}", "worried": "\u{246d}", "tired": "\u{2470}", "sceptical": "\u{246f}",
            "confused": "\u{2469}", "hurried": "\u{246a}", "joking": "\u{2466}", "grateful": "\u{2467}", "curious": "\u{2468}",
            "friendly": "\u{2465}", "elderly": "\u{2471}",
        ]
        let pairs01: [(String, [String])] = [
            ("operator", ["neutral", "warm", "cheerful", "empathetic", "calm", "dictation", "persuasive", "brisk"]),
            ("assistant", ["neutral", "warm", "cheerful", "empathetic", "calm", "dictation", "soothing"]),
            ("assistant_formal", ["neutral", "warm", "cheerful", "empathetic", "calm", "dictation", "soothing"]),
            ("emotional", ["angry", "upset", "irritated", "worried", "tired", "sceptical", "confused", "hurried", "joking",
                           "grateful", "curious", "friendly", "calm", "elderly"]),
        ]
        let tokenizer = try Tokenizer(json: Data(contentsOf: modelFile("tokenizer.json")))
        let tts = try Gapiring()
        var pairs = 0
        for (role, manners) in pairs01 {
            for manner in manners {
                pairs += 1
                let want = roles01[role]! + manners01[manner]!
                XCTAssertEqual(try Speech.tags(role: role, manner: manner), want, "\(role)/\(manner)")
                let ids = try tts.tokens("Salom, qalaysiz?", role: role, manner: manner)
                XCTAssertEqual(Array(ids.prefix(2)), tokenizer.encode(want), "\(role)/\(manner): the ids in front")
                let audio = try tts.speak("Salom, qalaysiz?", voice: "f1", role: role, manner: manner, seed: 3)
                XCTAssertTrue(audio.count > 12000 && audio.contains { abs($0) > 0.05 }, "\(role)/\(manner) is silent")
            }
        }
        XCTAssertEqual(pairs, 36)
        // The call forms of 0.1.7, as an app wrote them.
        _ = try tts.speak("Salom.")
        _ = try tts.speak("Salom.", voice: "m1", role: "operator")
        _ = try tts.tokens("Salom.", role: "emotional", manner: "joking")
        _ = try Speech.full("Salom.", role: "assistant", manner: "warm")
        try tts.stream("Salom.", voice: "f1", role: "assistant", manner: "warm", seed: 2, pause: 0.25) { _ in false }
        if pairs < 0 {   // compiled, never run: play would use the audio output
            tts.play("Salom.", voice: "f1", role: "assistant", manner: "warm", seed: 1, pause: 0.25) { _ in }
            tts.play("Salom.")
            tts.stop()
        }
    }

    /// ONNX Runtime's telemetry is off: the bindings set ORT_DISABLE_TELEMETRY=1 before ONNX Runtime starts (checked by
    /// hand: no connections to Microsoft's collector from the simulator or from a Mac holding a session 90 s).
    func testTelemetryOff() throws {
        _ = try Gapiring()
        XCTAssertEqual(getenv("ORT_DISABLE_TELEMETRY").map { String(cString: $0) }, "1")
    }

    /// The lines of speak_lines.jsonl at seed 3 with their settings, and a slowly dictated number: not silent, ended by
    /// the model and not by the length limit, slow longer than normal longer than fast. The durations are printed next
    /// to the JavaScript and Kotlin runtimes'; the WAV files go to the temporary folder.
    func testSpeakLines() throws {
        var lines = try reference("speak_lines")
        lines.append(["id": "dictation_number", "voice": "f1", "role": "assistant", "manner": "dictation",
                      "text": "Aloqa raqamimizni yozib oling: to'qqiz, nol, uch, besh, bir, to'rt, olti, sakkiz, yetti."])
        let bundle = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: modelFile("bundle.json"))) as? [String: Any])
        let perSecond = (bundle["tokens_per_second_estimate"] as! NSNumber).doubleValue
        let padding = (bundle["gen_seconds_padding"] as! NSNumber).doubleValue
        let frameRate = (bundle["frame_rate"] as! NSNumber).doubleValue
        let tts = try Gapiring()
        var seconds: [String: Double] = [:], greetings: [String: [Float]] = [:]
        for line in lines {
            let id = line["id"] as! String, text = line["text"] as! String, role = line["role"] as! String
            let manner = line["manner"] as? String, pace = line["pace"] as? String
            let serious = line["serious"] as? Bool ?? false, hesitant = line["hesitant"] as? Bool ?? false
            let t = Date()
            let audio = try tts.speak(text, voice: line["voice"] as! String, role: role, manner: manner, seed: 3, pace: pace,
                                      serious: serious, hesitant: hesitant)
            let s = Double(audio.count) / 24000
            seconds[id] = s
            if id.hasPrefix("greeting") { greetings[id] = audio }
            let js = (line["seconds_javascript"] as? NSNumber)?.doubleValue, kt = (line["seconds_kotlin"] as? NSNumber)?.doubleValue
            print(String(format: "SPEAK %@: swift %.2f s, javascript %@, kotlin %@, rtf %.3f", id, s,
                         js.map { String(format: "%.2f s", $0) } ?? "-", kt.map { String(format: "%.2f s", $0) } ?? "-",
                         Date().timeIntervalSince(t) / s))
            XCTAssertTrue(audio.contains { abs($0) > 0.05 }, "\(id) is silent")
            let pieces = Speech.pieces(text, role: role)
            if pieces.count == 1 {   // the model closed the line: it stopped before the length limit
                let ids = try tts.tokens(text, role: role, manner: manner, pace: pace, serious: serious, hesitant: hesitant)
                let limit = Int((Double(ids.count) / perSecond + padding) * frameRate) * Int(24000 / frameRate)   // frames of 1920 samples
                XCTAssertLessThan(audio.count, limit, "\(id) was cut at the length limit")
            }
            try wav(audio, "gapiring_\(id).wav")
        }
        XCTAssertNotEqual(greetings["greeting"], greetings["greeting_hesitant"], "hesitant changes the delivery")
        XCTAssertGreaterThan(seconds["pace_slow"]!, seconds["pace_normal"]!)
        XCTAssertGreaterThan(seconds["pace_normal"]!, seconds["pace_fast"]!)
        XCTAssertTrue((16...20).contains(seconds["dictation_number"]!), "the dictated number is \(seconds["dictation_number"]!) s")
    }

    /// assistant_formal reads the same tokens as assistant but its own role symbol (U+2463), and speaks the line
    /// differently at the same seed. Both WAVs go to the temporary folder.
    func testFormalRole() throws {
        let text = GapiringTests.greeting
        let tts = try Gapiring()
        let lively = try tts.tokens(text, role: "assistant", manner: "warm")
        let formal = try tts.tokens(text, role: "assistant_formal", manner: "warm")
        XCTAssertEqual(lively.count, formal.count)
        XCTAssertEqual(zip(lively, formal).filter { $0 != $1 }.count, 1, "only the role token differs")
        for manner in Speech.roleManners["assistant"]! { XCTAssertNoThrow(try Speech.tags(role: "assistant_formal", manner: manner)) }
        XCTAssertThrowsError(try Speech.tags(role: "assistant_formal", manner: "persuasive"))
        var audio: [String: [Float]] = [:]
        for role in ["assistant", "assistant_formal"] {
            let a = try tts.speak(text, voice: "f1", role: role, manner: "warm", seed: 3)
            print(String(format: "%@: %.2f s", role, Double(a.count) / 24000))
            XCTAssertTrue(a.count > 24000 && a.contains { abs($0) > 0.05 }, "\(role) is silent")
            try wav(a, "gapiring_\(role).wav")
            audio[role] = a
        }
        XCTAssertNotEqual(audio["assistant"], audio["assistant_formal"])
    }

    /// A long text is spoken to the end, piece by piece: exactly each piece spoken on its own with the same seed, and
    /// 0.25 s of zeros between the pieces. The WAV goes to the temporary folder.
    func testLongText() throws {
        let text = GapiringTests.longText
        XCTAssertGreaterThan(text.unicodeScalars.count, 400)
        let pieces = Speech.splitText(text)
        XCTAssertGreaterThan(pieces.count, 1)
        let tts = try Gapiring()
        let t = Date()
        let audio = try tts.speak(text, voice: "f1", role: "assistant", manner: "warm", seed: 3)
        let seconds = Double(audio.count) / 24000
        print(String(format: "long text: %d code points, %d pieces, %.2f s of speech, rtf %.3f", text.unicodeScalars.count,
                     pieces.count, seconds, Date().timeIntervalSince(t) / seconds))
        var want: [Float] = []
        for (i, piece) in pieces.enumerated() {
            if i > 0 { want += [Float](repeating: 0, count: 6000) }
            let part = try tts.speak(piece, voice: "f1", role: "assistant", manner: "warm", seed: 3)
            XCTAssertTrue(part.count > 24000 && part.contains { abs($0) > 0.05 }, "piece \(i) is \(part.count) samples")
            want += part
        }
        XCTAssertEqual(audio.count, want.count)
        XCTAssertTrue(audio == want, "the long text differs from its pieces spoken one by one")
        try wav(audio, "gapiring_long.wav")
    }

    /// A false from the callback ends the whole text, not only its piece.
    func testStopEndsText() throws {
        let tts = try Gapiring()
        var chunks = 0
        try tts.stream(GapiringTests.longText, voice: "f1", role: "assistant", manner: "warm") { _ in chunks += 1; return false }
        XCTAssertEqual(chunks, 1)
    }

    /// Three lines are spoken; the WAV files go to the temporary folder (printed) for a listen and a recogniser.
    func testSpeaks() throws {
        let t0 = Date()
        let tts = try Gapiring()
        print("load \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
        let lines: [(String, String, String, String)] = [
            (GapiringTests.greeting, "f1", "assistant", "warm"),
            ("Bugun obunani rasmiylashtirsangiz, birinchi oy uchun to'liq ellik foiz chegirma beriladi, imkoniyatni qo'ldan boy bermang.", "m1", "operator", "calm"),
            ("Oyimning tug'ilgan kuniga sovg'a buyurtma qilgandim, [sigh] vaqtida olib kelmadinglar, rosa xafa bo'ldim to'g'risi.", "f1", "emotional", "upset"),
        ]
        for (i, (text, voice, role, manner)) in lines.enumerated() {
            let t = Date()
            var first = -1.0
            var audio: [Float] = []
            try tts.stream(text, voice: voice, role: role, manner: manner, seed: 3) { chunk in
                if first < 0 { first = Date().timeIntervalSince(t) * 1000 }
                audio += chunk
                return true
            }
            let seconds = Double(audio.count) / 24000
            print(String(format: "line %d: %.2f s of speech, first audio %.0f ms, rtf %.3f", i, seconds, first, Date().timeIntervalSince(t) / seconds))
            XCTAssertTrue(seconds > 1.5 && seconds < 20, "line \(i) is \(seconds) s")
            XCTAssertTrue(audio.contains { abs($0) > 0.05 }, "line \(i) is silent")
            try wav(audio, "gapiring_\(i).wav")
        }
    }
}
