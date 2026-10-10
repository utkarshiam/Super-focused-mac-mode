import Foundation

/// Name normalisation for "one name per thing". A key is the folded form two spellings of the same thing
/// share: case, diacritics, width and punctuation are ignored, and per kind:
/// - people: honorifics and titles dropped ("Mr", "Dr", "Shri", "ji", "sir", "sahab", "bhai", "san");
/// - organisations: a leading "the", "&"/"and" and legal suffixes dropped ("Pvt Ltd", "Inc", "LLC", "GmbH");
/// - topics and areas: "&"/"and" dropped and the last word singular ("Store pilots" = "store pilot");
/// - projects: a trailing "project" dropped ("Billing API project" = "Billing API").
public enum EntityNames {
    /// The matching key for `name` as an entity of `kind` ("" when nothing is left).
    public static func key(_ name: String, kind: EntityKind) -> String {
        var words = TextFold.words(name)
        switch kind {
        case .person:
            let stripped = stripHonorifics(words)
            if !stripped.isEmpty { words = stripped }
        case .organisation:
            words.removeAll { $0 == "and" }
            if words.first == "the", words.count > 1 { words.removeFirst() }
            var changed = true
            while changed && words.count > 1 {
                changed = false
                for suffix in orgSuffixes where words.count > suffix.count && Array(words.suffix(suffix.count)) == suffix {
                    words.removeLast(suffix.count)
                    changed = true
                    break
                }
            }
        case .topic, .area:
            words.removeAll { $0 == "and" }
            if words.first == "the", words.count > 1 { words.removeFirst() }
            if let last = words.last { words[words.count - 1] = singular(last) }
        case .project:
            if words.first == "the", words.count > 1 { words.removeFirst() }
            if words.count > 1, let last = words.last, last == "project" || last == "projects" { words.removeLast() }
        }
        return words.joined(separator: " ")
    }

    /// "person:rohan mehta": a key that can't collide across kinds.
    public static func scopedKey(_ name: String, kind: EntityKind) -> String {
        kind.rawValue + ":" + key(name, kind: kind)
    }

    static let leadingHonorifics: Set<String> = [
        "mr", "mrs", "ms", "miss", "mx", "dr", "prof", "professor", "sir", "dame", "shri", "sri", "shree", "smt",
        "kumari", "km", "mme", "mlle", "herr", "frau", "sr", "sra", "srta", "don", "dona", "capt", "col", "hon",
    ]
    static let trailingHonorifics: Set<String> = [
        "ji", "jee", "sir", "sahab", "saheb", "sahib", "bhai", "bhaiya", "didi", "garu", "san", "sama", "kun", "chan",
        "madam", "maam", "phd", "md", "esq",
    ]

    /// Words with titles removed from the front and back (never everything).
    static func stripHonorifics(_ words: [String]) -> [String] {
        var w = words
        while w.count > 1, let first = w.first, leadingHonorifics.contains(first) { w.removeFirst() }
        while w.count > 1, let last = w.last, trailingHonorifics.contains(last) { w.removeLast() }
        return w
    }

    /// Legal suffixes, longest first so "pvt ltd" goes before "ltd".
    static let orgSuffixes: [[String]] = [
        ["private", "limited"], ["pvt", "ltd"], ["pte", "ltd"], ["pty", "ltd"], ["co", "ltd"], ["s", "a"],
        ["pvt"], ["private"], ["ltd"], ["limited"], ["inc"], ["incorporated"], ["llc"], ["llp"], ["lp"], ["plc"],
        ["corp"], ["corporation"], ["co"], ["company"], ["gmbh"], ["ag"], ["sa"], ["sas"], ["sarl"], ["bv"], ["nv"],
        ["oy"], ["ab"], ["as"], ["kk"], ["srl"], ["spa"], ["pte"], ["pty"], ["group"],
    ]

    /// A rough English singular, enough to make "pilots"/"pilot" and "strategies"/"strategy" one key.
    static func singular(_ word: String) -> String {
        guard word.count > 3, word.last == "s", word.allSatisfy(\.isLetter) else { return word }
        if word.hasSuffix("ies") && word.count > 4 { return String(word.dropLast(3)) + "y" }
        if word.hasSuffix("sses") { return String(word.dropLast(2)) }
        for ending in ["xes", "ches", "shes", "zzes"] where word.hasSuffix(ending) { return String(word.dropLast(2)) }
        for ending in ["ss", "us", "is", "ous"] where word.hasSuffix(ending) { return word }
        return String(word.dropLast())
    }

    /// The nicest spelling for display: for people a spelled-out full name (no initials) first; then the most
    /// often seen; then properly cased ("José Núñez" over "JOSÉ NÚÑEZ" and "jose nunez"), with accents, without
    /// a legal suffix or title; then alphabetical (stable).
    static func preferredDisplay(_ spellings: [String: Int], kind: EntityKind) -> String {
        let candidates = spellings.keys.sorted()
        guard var best = candidates.first else { return "" }
        func score(_ s: String) -> [Int] {
            let words = TextFold.words(s)
            let keyWords = key(s, kind: kind).split(separator: " ")
            var out: [Int] = []
            if kind == .person {
                out.append(keyWords.allSatisfy { $0.count > 1 } ? 1 : 0)
                out.append(min(keyWords.count, 2))
            }
            out.append(spellings[s] ?? 0)
            let letters = s.filter(\.isLetter)
            let proper = (s.first?.isUppercase ?? false) && !(letters.count > 3 && letters.allSatisfy(\.isUppercase)) ? 1 : 0
            out.append(proper)
            out.append(words.count == keyWords.count ? 1 : 0)
            out.append(s.unicodeScalars.filter { $0.value > 127 }.count)
            return out
        }
        for s in candidates.dropFirst() where score(s).lexicographicallyPrecedes(score(best)) == false && score(s) != score(best) { best = s }
        return best
    }

    /// Levenshtein distance, capped (returns `cap + 1` once exceeded) so long strings stay cheap.
    static func editDistance(_ a: String, _ b: String, cap: Int = 3) -> Int {
        let x = Array(a), y = Array(b)
        if abs(x.count - y.count) > cap { return cap + 1 }
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            var rowMin = current[0]
            for j in 1...y.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
                rowMin = min(rowMin, current[j])
            }
            if rowMin > cap { return cap + 1 }
            swap(&previous, &current)
        }
        return previous[y.count]
    }

    /// "International Business Machines" → "ibm" (nil for one word).
    static func acronym(_ key: String) -> String? {
        let words = key.split(separator: " ")
        guard words.count >= 2 else { return nil }
        return String(words.compactMap(\.first))
    }
}

/// Stable ids derived from text (name-based UUIDs), for seeds and tests.
enum BrainIDs {
    /// A UUID that is always the same for `text` (FNV-1a based, version-5 layout bits).
    static func stable(_ text: String) -> UUID {
        var bytes = Array(text.utf8)
        // FNV-1a over the bytes, twice with different seeds, gives 128 deterministic bits without CryptoKit.
        func fnv(_ seed: UInt64) -> UInt64 {
            var h = seed
            for b in bytes { h = (h ^ UInt64(b)) &* 0x100_0000_01B3 }
            return h
        }
        let a = fnv(0xCBF2_9CE4_8422_2325), b = fnv(0x84222325CBF29CE4 ^ UInt64(bytes.count))
        bytes = withUnsafeBytes(of: a.bigEndian, Array.init) + withUnsafeBytes(of: b.bigEndian, Array.init)
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// A deterministic 64-bit hash of a string (Swift's `Hasher` is seeded per process).
    static func hash(_ text: String) -> UInt64 {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for b in text.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01B3 }
        return h
    }
}
