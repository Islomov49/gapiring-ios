import Foundation

/// The Unigram tokenizer of tokenizer.json (added tokens first, "▁" word marks, Viterbi, byte fallback): the same ids as
/// the Python runtime gives. Works on Unicode scalars, never on Characters: Swift's String compares canonically
/// equivalent text as equal, the vocabulary does not.
public final class Tokenizer {
    private typealias Scalars = [Unicode.Scalar]
    private var pieces: [Scalars: (id: Int, score: Double)] = [:]
    private var bytes = [Int](repeating: -1, count: 256)
    private var added: [(content: Scalars, id: Int)] = []
    private let unkId: Int
    private var unkScore = 0.0
    private var maxLen = 1
    private static let mark: Unicode.Scalar = "▁"

    public init(json data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = root["model"] as? [String: Any], let vocab = model["vocab"] as? [[Any]],
              let unk = model["unk_id"] as? Int, let tokens = root["added_tokens"] as? [[String: Any]] else {
            throw GapiringError.model("tokenizer.json: not the expected layout")
        }
        unkId = unk
        var lowest = Double.infinity
        for (i, row) in vocab.enumerated() {
            guard let piece = row[0] as? String, let score = (row[1] as? NSNumber)?.doubleValue else {
                throw GapiringError.model("tokenizer.json: vocabulary row \(i)")
            }
            let key = Array(piece.unicodeScalars)
            pieces[key] = (i, score)
            lowest = min(lowest, score)
            maxLen = max(maxLen, key.count)
        }
        unkScore = lowest - 10
        added = tokens.compactMap { t in
            guard let c = t["content"] as? String, let id = t["id"] as? Int else { return nil }
            return (Array(c.unicodeScalars), id)
        }.sorted { $0.content.count > $1.content.count }
        for b in 0..<256 {
            if let hit = pieces[Array(String(format: "<0x%02X>", b).unicodeScalars)] { bytes[b] = hit.id }
        }
    }

    private func viterbi(_ word: ArraySlice<Unicode.Scalar>) -> [Int] {
        let chars = Array(word), n = chars.count
        var best = [Double](repeating: -.infinity, count: n + 1)
        var backFrom = [Int](repeating: 0, count: n + 1), backId = [Int](repeating: 0, count: n + 1)
        best[0] = 0
        for i in 0..<n where best[i] != -.infinity {
            var any = false
            for j in i..<min(n, i + maxLen) {
                guard let hit = pieces[Array(chars[i...j])] else { continue }
                any = any || j == i
                let s = best[i] + hit.score
                if s > best[j + 1] { best[j + 1] = s; backFrom[j + 1] = i; backId[j + 1] = hit.id }
            }
            if !any {   // no piece starts with this character: unknown, then byte fallback
                let s = best[i] + unkScore
                if s > best[i + 1] { best[i + 1] = s; backFrom[i + 1] = i; backId[i + 1] = -1 }
            }
        }
        var out: [Int] = []
        var k = n
        while k > 0 {
            let i = backFrom[k]
            if backId[k] == -1 {
                var s = String.UnicodeScalarView()
                s.append(contentsOf: chars[i..<k])
                for b in Array(String(s).utf8).reversed() { out.append(bytes[Int(b)] == -1 ? unkId : bytes[Int(b)]) }
            } else {
                out.append(backId[k])
            }
            k = i
        }
        return out.reversed()
    }

    private func segment(_ seg: ArraySlice<Unicode.Scalar>) -> [Int] {
        if seg.isEmpty { return [] }
        let s: Scalars = [Tokenizer.mark] + seg.map { $0 == " " ? Tokenizer.mark : $0 }
        var out: [Int] = []
        var start = 0
        for i in 1...s.count where i == s.count || s[i] == Tokenizer.mark {
            out += viterbi(s[start..<i])
            start = i
        }
        return out
    }

    private static func find(_ needle: Scalars, in hay: ArraySlice<Unicode.Scalar>) -> Int? {
        guard !needle.isEmpty, hay.count >= needle.count else { return nil }
        for p in hay.startIndex...(hay.endIndex - needle.count) where Array(hay[p..<(p + needle.count)]) == needle { return p }
        return nil
    }

    public func encode(_ text: String) -> [Int] {
        let all = Array(text.unicodeScalars)
        var ids: [Int] = []
        var from = 0
        while from < all.count {
            var pos: Int? = nil
            var tok: (content: Scalars, id: Int)? = nil
            for a in added {
                guard let p = Tokenizer.find(a.content, in: all[from...]) else { continue }
                if pos == nil || p < pos! || (p == pos! && a.content.count > tok!.content.count) { pos = p; tok = a }
            }
            guard let p = pos, let t = tok else { ids += segment(all[from...]); break }
            ids += segment(all[from..<p])
            ids.append(t.id)
            from = p + t.content.count
        }
        return ids
    }
}
