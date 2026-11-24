import XCTest
@testable import Gapiring

/// Reference data sits in Tests/GapiringTests/Reference (made by the Python runtime, see TZ.md).
final class GapiringTests: XCTestCase {
    private func modelFile(_ name: String) throws -> URL {
        let dir = try XCTUnwrap(Bundle(for: Gapiring.self).url(forResource: "Model", withExtension: nil)
            ?? Bundle.allBundles.compactMap { $0.url(forResource: "Model", withExtension: nil) }.first, "Model folder not found in the bundles")
        return dir.appendingPathComponent(name)
    }

    /// The random generator gives the numbers of the JavaScript and Kotlin runtimes.
    func testRandom() {
        var r = Mulberry32(3)
        let want = [0.7202267837710679, 0.03866216051392257, 0.4561921926215291, 0.07492800964973867]
        for w in want { XCTAssertEqual(r.next(), w, accuracy: 0) }
    }

    /// The text front and the token ids equal the Python runtime's on every reference case (146).
    func testTextAndTokens() throws {
        let tokenizer = try Tokenizer(json: Data(contentsOf: modelFile("tokenizer.json")))
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Reference/tok_cases", withExtension: "jsonl"))
        var cases = 0, badText = 0, badIds = 0
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
            let r = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            cases += 1
            let raw = r["raw"] as! String, tags = r["tags"] as! String, text = r["text"] as! String
            let full = r["full"] as! String, ids = (r["ids"] as! [NSNumber]).map { $0.intValue }
            if Array(Speech.pocketText(raw, tags: tags).unicodeScalars) != Array(text.unicodeScalars) { badText += 1; print("TEXT", raw) }
            if tokenizer.encode(full) != ids { badIds += 1; print("IDS", full.prefix(60)) }
        }
        print("cases \(cases), text mismatches \(badText), id mismatches \(badIds)")
        XCTAssertEqual(cases, 146)
        XCTAssertEqual(badText, 0)
        XCTAssertEqual(badIds, 0)
    }

    /// ONNX Runtime's telemetry is off: the bindings set ORT_DISABLE_TELEMETRY=1 before ONNX Runtime starts (checked by
    /// hand: no connections to Microsoft's collector from the simulator or from a Mac holding a session 90 s).
    func testTelemetryOff() throws {
        _ = try Gapiring()
        XCTAssertEqual(getenv("ORT_DISABLE_TELEMETRY").map { String(cString: $0) }, "1")
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
            var wav = Data()
            func put<T>(_ v: T) { withUnsafeBytes(of: v) { wav.append(contentsOf: $0) } }
            wav.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + audio.count * 2)); wav.append(contentsOf: Array("WAVEfmt ".utf8))
            put(UInt32(16)); put(UInt16(1)); put(UInt16(1)); put(UInt32(24000)); put(UInt32(48000)); put(UInt16(2)); put(UInt16(16))
            wav.append(contentsOf: Array("data".utf8)); put(UInt32(audio.count * 2))
            for s in audio { put(Int16(max(-1, min(1, s)) * 32767)) }
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("gapiring_\(i).wav")
            try wav.write(to: out)
            print("wav", out.path)
        }
    }
}
