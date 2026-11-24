import XCTest
@testable import Gapiring

/// Reference data sits in Tests/GapiringTests/Reference: tok_cases_public.jsonl and split_cases_public.jsonl, the files
/// every Gapiring runtime checks itself against (made by the Python runtime).
final class GapiringTests: XCTestCase {
    private func modelFile(_ name: String) throws -> URL {
        let dir = try XCTUnwrap(Bundle(for: Gapiring.self).url(forResource: "Model", withExtension: nil)
            ?? Bundle.allBundles.compactMap { $0.url(forResource: "Model", withExtension: nil) }.first, "Model folder not found in the bundles")
        return dir.appendingPathComponent(name)
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

    /// The README's lines joined (more than 400 code points), typed with U+02BB as an Uzbek phone keyboard does.
    static let longText = [
        "Assalomu alaykum! Namuna kompaniyasining virtual yordamchisiman, sizga qanday yordam bera olaman?",
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

    /// The text front and the token ids equal the Python runtime's on every reference case (148, the apostrophe
    /// variants among them).
    func testTextAndTokens() throws {
        let tokenizer = try Tokenizer(json: Data(contentsOf: modelFile("tokenizer.json")))
        var cases = 0, badText = 0, badIds = 0
        for r in try reference("tok_cases_public") {
            cases += 1
            let raw = r["raw"] as! String, tags = r["tags"] as! String, text = r["text"] as! String
            let full = r["full"] as! String, ids = (r["ids"] as! [NSNumber]).map { $0.intValue }
            if Array(Speech.pocketText(raw, tags: tags).unicodeScalars) != Array(text.unicodeScalars) { badText += 1; print("TEXT", raw) }
            if tokenizer.encode(full) != ids { badIds += 1; print("IDS", full.prefix(60)) }
        }
        print("cases \(cases), text mismatches \(badText), id mismatches \(badIds)")
        XCTAssertEqual(cases, 148)
        XCTAssertEqual(badText, 0)
        XCTAssertEqual(badIds, 0)
    }

    /// splitText cuts every reference text into the pieces of the other runtimes, scalar by scalar (75 cases).
    func testSplitText() throws {
        var cases = 0, bad = 0
        for r in try reference("split_cases_public") {
            cases += 1
            let text = r["text"] as! String, want = r["pieces"] as! [String]
            let got = Speech.splitText(text)
            if got.map({ Array($0.unicodeScalars) }) != want.map({ Array($0.unicodeScalars) }) {
                bad += 1
                print("SPLIT", text.prefix(60), "got", got.count, "want", want.count)
            }
        }
        print("split cases \(cases), mismatches \(bad)")
        XCTAssertEqual(cases, 75)
        XCTAssertEqual(bad, 0)
    }

    /// ONNX Runtime's telemetry is off: the bindings set ORT_DISABLE_TELEMETRY=1 before ONNX Runtime starts (checked by
    /// hand: no connections to Microsoft's collector from the simulator or from a Mac holding a session 90 s).
    func testTelemetryOff() throws {
        _ = try Gapiring()
        XCTAssertEqual(getenv("ORT_DISABLE_TELEMETRY").map { String(cString: $0) }, "1")
    }

    /// The three README lines at seed 3 keep their lengths: 6.16, 7.68 and 8.00 s (77, 96 and 100 frames of 80 ms).
    func testReadmeLines() throws {
        let tts = try Gapiring()
        let lines: [(String, String, String, String)] = [
            ("Assalomu alaykum! Namuna kompaniyasining virtual yordamchisiman, sizga qanday yordam bera olaman?", "f1", "assistant", "warm"),
            ("Bugun obunani rasmiylashtirsangiz, birinchi oy uchun to'liq ellik foiz chegirma beriladi, imkoniyatni qo'ldan boy bermang.", "m1", "operator", "calm"),
            ("Kechasi o'g'limning isitmasi chiqqanda shifokoringiz tez yetib kelib yordam berdi, klinika jamoasiga ming rahmat, baraka topinglar!", "f1", "emotional", "grateful"),
        ]
        let counts = try lines.map { try tts.speak($0.0, voice: $0.1, role: $0.2, manner: $0.3, seed: 3).count }
        print("README lines:", counts.map { String(format: "%.2f s", Double($0) / 24000) })
        XCTAssertEqual(counts, [147_840, 184_320, 192_000])
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
            ("Assalomu alaykum! Namuna kompaniyasining virtual yordamchisiman, sizga qanday yordam bera olaman?", "f1", "assistant", "warm"),
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
