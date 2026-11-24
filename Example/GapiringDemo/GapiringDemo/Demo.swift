import Foundation
import Gapiring

/// The model, the lines, playback and the measurements. Launch with `-bench` to measure at once (two passes); the
/// report goes to the screen, to stdout as one `GAPIRING_BENCH {json}` line and to Documents/bench.json.
final class Demo: ObservableObject {
    struct Line {
        let text, voice, role, manner: String
    }

    /// The three example lines of the package's README (the first two are also in testSpeaks), then a longer text, spoken
    /// piece by piece: the README's lines joined, typed with U+02BB as an Uzbek phone keyboard does (testLongText).
    static let lines = [
        Line(text: "Assalomu alaykum! Namuna kompaniyasining virtual yordamchisiman, sizga qanday yordam bera olaman?",
             voice: "f1", role: "assistant", manner: "warm"),
        Line(text: "Bugun obunani rasmiylashtirsangiz, birinchi oy uchun to'liq ellik foiz chegirma beriladi, imkoniyatni qo'ldan boy bermang.",
             voice: "m1", role: "operator", manner: "calm"),
        Line(text: "Kechasi o'g'limning isitmasi chiqqanda shifokoringiz tez yetib kelib yordam berdi, klinika jamoasiga ming rahmat, baraka topinglar!",
             voice: "f1", role: "emotional", manner: "grateful"),
        Line(text: "Assalomu alaykum! Namuna kompaniyasining virtual yordamchisiman, sizga qanday yordam bera olaman? Bugun obunani rasmiylashtirsangiz, birinchi oy uchun to\u{02BB}liq ellik foiz chegirma beriladi, imkoniyatni qo\u{02BB}ldan boy bermang. Kechasi o\u{02BB}g\u{02BB}limning isitmasi chiqqanda shifokoringiz tez yetib kelib yordam berdi, klinika jamoasiga ming rahmat, baraka topinglar! Oyimning tug\u{02BB}ilgan kuniga sovg\u{02BB}a buyurtma qilgandim, vaqtida olib kelmadinglar, rosa xafa bo\u{02BB}ldim to\u{02BB}g\u{02BB}risi.",
             voice: "f1", role: "assistant", manner: "warm"),
    ]
    static let threads = 2

    @Published var status = "Loading the model…"
    @Published var ready = false
    @Published var playing = false
    @Published var measuring = false
    @Published var selected = 0
    @Published var report: [String] = []

    private var tts: Gapiring?
    private let work = DispatchQueue(label: "uz.gapi.gapiring.demo", qos: .userInitiated)
    private var loadMs = 0.0
    private var memLaunch = 0, memLoaded = 0

    var busy: Bool { !ready || playing || measuring }

    func load() {
        guard tts == nil else { return }
        memLaunch = Memory.footprint()
        let bench = ProcessInfo.processInfo.arguments.contains("-bench")
        work.async { [self] in
            let t = Date()
            do {
                let tts = try Gapiring(threads: Demo.threads)
                let ms = Date().timeIntervalSince(t) * 1000
                let mem = Memory.footprint()
                DispatchQueue.main.async { [self] in
                    self.tts = tts
                    loadMs = ms
                    memLoaded = mem
                    ready = true
                    status = String(format: "Model loaded in %.0f ms (%d threads), memory %@", ms, Demo.threads, Memory.mb(mem))
                    if bench { measure(passes: 2) }
                }
            } catch {
                DispatchQueue.main.async { [self] in status = "Could not load the model: \(error)" }
            }
        }
    }

    func play() {
        guard let tts, !busy else { return }
        let line = Demo.lines[selected]
        playing = true
        status = "Speaking line \(selected + 1)…"
        tts.play(line.text, voice: line.voice, role: line.role, manner: line.manner) { error in
            DispatchQueue.main.async { [self] in
                playing = false
                status = error.map { "Playback failed: \($0)" } ?? "Done"
            }
        }
    }

    func stop() {
        tts?.stop()
    }

    /// Each line through `stream` (no playback): first audio, real-time factor; memory sampled at every chunk.
    func measure(passes: Int = 1) {
        guard let tts, !busy else { return }
        measuring = true
        status = "Measuring…"
        report = []
        let loadMs = loadMs, memLaunch = memLaunch, memLoaded = memLoaded
        work.async {
            var rows: [[String: Any]] = []
            var text: [String] = []
            var sampledPeak = Memory.footprint()
            var failure: String?
            for pass in 1...passes {
                for (i, line) in Demo.lines.enumerated() {
                    let t = Date()
                    var first = -1.0
                    var samples = 0
                    do {
                        try tts.stream(line.text, voice: line.voice, role: line.role, manner: line.manner, seed: 3) { chunk in
                            if first < 0 { first = Date().timeIntervalSince(t) * 1000 }
                            samples += chunk.count
                            sampledPeak = max(sampledPeak, Memory.footprint())
                            return true
                        }
                    } catch {
                        failure = "line \(i + 1): \(error)"
                        break
                    }
                    let wall = Date().timeIntervalSince(t)
                    let seconds = Double(samples) / Double(tts.sampleRate)
                    rows.append(["pass": pass, "line": i + 1, "audio_s": round3(seconds), "first_audio_ms": round3(first),
                                 "gen_s": round3(wall), "rtf": round3(wall / seconds)])
                    text.append(String(format: "pass %d · line %d: %.2f s audio, first %.0f ms, RTF %.3f", pass, i + 1, seconds, first, wall / seconds))
                }
            }
            let peak = max(sampledPeak, Memory.peak())
            let summary: [String: Any] = [
                "device": Device.model, "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "package": Gapiring.version, "threads": Demo.threads, "load_ms": round3(loadMs),
                "mem_launch_mb": Memory.mbValue(memLaunch), "mem_loaded_mb": Memory.mbValue(memLoaded),
                "mem_peak_mb": Memory.mbValue(peak), "thermal": Device.thermal, "lines": rows,
                "error": failure ?? NSNull(),
            ]
            let json = (try? JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])) ?? Data()
            print("GAPIRING_BENCH " + String(decoding: json, as: UTF8.self))
            fflush(stdout)
            if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                try? json.write(to: docs.appendingPathComponent("bench.json"))
            }
            let head = [
                "\(Device.model) · \(ProcessInfo.processInfo.operatingSystemVersionString)",
                String(format: "load %.0f ms · %d threads · thermal %@", loadMs, Demo.threads, Device.thermal),
                "memory: launch \(Memory.mb(memLaunch)), loaded \(Memory.mb(memLoaded)), peak \(Memory.mb(peak))",
            ]
            DispatchQueue.main.async { [self] in
                measuring = false
                report = head + text
                status = failure.map { "Measuring failed: \($0)" } ?? "Measured"
            }
        }
    }
}

private func round3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }

enum Memory {
    private static func info() -> task_vm_info_data_t? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? info : nil
    }

    /// The physical footprint: what Xcode's memory gauge shows and what the system's memory limit counts.
    static func footprint() -> Int { info().map { Int($0.phys_footprint) } ?? -1 }
    /// The highest footprint of the process so far, as the kernel counts it.
    static func peak() -> Int { info().map { Int($0.ledger_phys_footprint_peak) } ?? -1 }
    static func mbValue(_ bytes: Int) -> Double { (Double(bytes) / 1_048_576 * 10).rounded() / 10 }
    static func mb(_ bytes: Int) -> String { String(format: "%.0f MB", mbValue(bytes)) }
}

enum Device {
    static var model: String {
        var s = utsname()
        uname(&s)
        return withUnsafeBytes(of: &s.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    static var thermal: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}
