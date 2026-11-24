import Foundation

/// Roles and manners by name, and the text front: punctuation, sound tags, the role and manner in front of the text.
public enum Speech {
    public static let roles: [String: String] = ["operator": "\u{2460}", "assistant": "\u{2462}", "emotional": "\u{2461}"]
    static let manners: [String: String] = [
        "calm": "\u{2464}", "neutral": "\u{2472}", "warm": "\u{2473}", "cheerful": "\u{2474}", "empathetic": "\u{2475}",
        "dictation": "\u{2476}", "persuasive": "\u{2477}", "brisk": "\u{2478}", "soothing": "\u{2479}", "angry": "\u{246c}",
        "upset": "\u{246e}", "irritated": "\u{246b}", "worried": "\u{246d}", "tired": "\u{2470}", "sceptical": "\u{246f}",
        "confused": "\u{2469}", "hurried": "\u{246a}", "joking": "\u{2466}", "grateful": "\u{2467}", "curious": "\u{2468}",
        "friendly": "\u{2465}", "elderly": "\u{2471}",
    ]
    /// The manners each role speaks in: roleManners["emotional"] = angry, upset, ...
    public static let roleManners: [String: [String]] = [
        "operator": ["neutral", "warm", "cheerful", "empathetic", "calm", "dictation", "persuasive", "brisk"],
        "assistant": ["neutral", "warm", "cheerful", "empathetic", "calm", "dictation", "soothing"],
        "emotional": ["angry", "upset", "irritated", "worried", "tired", "sceptical", "confused", "hurried", "joking",
                      "grateful", "curious", "friendly", "calm", "elderly"],
    ]
    public static let voices = ["f1", "m1"]

    private static let events: [(String, String)] = [("laugh", "§"), ("pause", "¦"), ("breath", "¶"), ("sigh", "¤")]
    private static let map: [Unicode.Scalar: String] = [
        "…": "...", "«": "", "»": "", "\"": "", "“": "", "”": "", "„": "", "(": "", ")": "", ":": ",", ";": ",",
        // The apostrophe variants become the plain one the model was taught: Uzbek keyboards type U+02BB and U+02BC.
        "\u{02BB}": "'", "\u{02BC}": "'", "\u{2018}": "'", "\u{2019}": "'", "\u{2032}": "'", "\u{02B9}": "'", "\u{0060}": "'",
    ]

    public static func tags(role: String, manner: String) throws -> String {
        guard let r = roles[role], let m = manners[manner], roleManners[role]?.contains(manner) == true else {
            throw GapiringError.unknown("role/manner \(role)/\(manner): see Speech.roleManners")
        }
        return r + m
    }

    private static func replace(_ s: String, _ pattern: String, _ with: String) -> String {
        // ICU: \s is Unicode white space
        let re = try! NSRegularExpression(pattern: pattern)
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: with)
    }

    public static func pocketText(_ text: String, tags: String = "") -> String {
        var t = ""
        for u in text.unicodeScalars {
            if let r = map[u] { t += r } else { t.unicodeScalars.append(u) }
        }
        t = replace(t, "\\s+[—–-]\\s+|[—–]", ", ")
        t = replace(t, ",(\\s*,)+", ",")
        t = replace(t, "\\s+([,.!?])", "$1")
        t = replace(t, "\\s+", " ").trimmingCharacters(in: .whitespacesAndNewlines)
        for (name, symbol) in events { t = replace(t, "\\s*\\[\(name)\\]\\s*", symbol) }
        return tags + t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The text the tokenizer gets: the text front, closed with a full stop when it has no closing mark.
    public static func full(_ text: String, role: String, manner: String) throws -> String {
        let t = pocketText(text, tags: try tags(role: role, manner: manner))
        if let last = t.unicodeScalars.last, ".!?…".unicodeScalars.contains(last) { return t }
        return t + "."
    }

    static func words(_ text: String) -> Int {
        text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
    }

    // MARK: Texts of any length

    /// White space, the same list in every Gapiring runtime.
    private static let ws = "[ \\t\\n\\u000B\\f\\r\\u0085\\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000]"
    private static let wsSet: Set<Unicode.Scalar> = Set(" \t\n\u{0B}\u{0C}\r\u{85}\u{A0}\u{1680}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}".unicodeScalars)
        .union((0x2000...0x200A).map { Unicode.Scalar(UInt32($0))! })
    private static let sentenceCut = try! NSRegularExpression(pattern: "([.!?…])[\"”»)]*\(ws)+|\\n+")
    private static let clauseCut = try! NSRegularExpression(pattern: "([,;:])\(ws)+|\(ws)+[—–\\-]\(ws)+")

    private static func size(_ s: String) -> Int { s.unicodeScalars.count }

    private static func trim(_ s: String) -> String {
        let u = s.unicodeScalars
        guard let a = u.firstIndex(where: { !wsSet.contains($0) }), let b = u.lastIndex(where: { !wsSet.contains($0) }) else { return "" }
        return String(u[a...b])
    }

    /// The text between the matches; a closing mark (group 1) stays with what it closes.
    private static func cut(_ re: NSRegularExpression, _ text: String) -> [String] {
        let u = text.unicodeScalars
        var out: [String] = [], start = u.startIndex
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let mark = Range(m.range(at: 1), in: text), all = Range(m.range, in: text)!
            out.append(String(u[start..<(mark?.upperBound ?? all.lowerBound)]))
            start = all.upperBound
        }
        out.append(String(u[start...]))
        return out
    }

    /// The pieces `stream`, `speak` and `play` speak a text in: sentences joined while they fit in `limit` code points,
    /// a sentence longer than `hard` cut at its commas, colons and dashes. A text of at most `limit` is one piece.
    public static func splitText(_ text: String, limit: Int = 150, hard: Int = 240) -> [String] {
        let text = trim(text)
        if size(text) <= limit { return text.isEmpty ? [] : [text] }
        var sentences: [String] = []
        for s in cut(sentenceCut, text).map(trim) where !s.isEmpty {
            if size(s) <= hard { sentences.append(s); continue }
            let clauses = cut(clauseCut, s).map(trim).filter { !$0.isEmpty }
            var part = ""
            for (i, c) in clauses.enumerated() {
                var clause = c
                if i < clauses.count - 1 {
                    while let last = clause.unicodeScalars.last, ",;:".unicodeScalars.contains(last) { clause.unicodeScalars.removeLast() }
                }
                if !part.isEmpty && size(part) + 2 + size(clause) > limit {
                    sentences.append(part)
                    part = clause
                } else {
                    part = part.isEmpty ? clause : part + ", " + clause
                }
            }
            if !part.isEmpty { sentences.append(part) }
        }
        var pieces: [String] = []
        for s in sentences {
            if let last = pieces.last, size(last) + 1 + size(s) <= limit { pieces[pieces.count - 1] = last + " " + s }
            else { pieces.append(s) }
        }
        return pieces
    }
}

public enum GapiringError: Error, CustomStringConvertible {
    case unknown(String)
    case model(String)
    public var description: String {
        switch self { case .unknown(let s), .model(let s): return s }
    }
}

/// The random generator the other Gapiring runtimes use (the same numbers for a seed).
struct Mulberry32 {
    private var seed: UInt32
    init(_ seed: UInt32) { self.seed = seed }
    mutating func next() -> Double {
        seed = seed &+ 0x6D2B_79F5
        var t = (seed ^ (seed >> 15)) &* (1 | seed)
        t = (t &+ ((t ^ (t >> 7)) &* (61 | t))) ^ t
        return Double(t ^ (t >> 14)) / 4294967296.0
    }
}
