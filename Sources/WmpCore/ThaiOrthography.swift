import Foundation

/// Structural rules of written Thai. Latin text typed on the Thai layout almost
/// always breaks one of them within the first couple of characters ("hello"
/// lands as "้ำสสน", which opens with a tone mark), so this is the cheapest and
/// sharpest signal we have - no dictionary needed.
public enum ThaiOrthography {
    enum Class {
        case consonant
        case leadingVowel      // เ แ โ ใ ไ
        case followingVowel    // ะ า ำ ๅ ๆ ฯ
        case aboveVowel        // ั ิ ี ึ ื ็ ํ
        case belowVowel        // ุ ู ฺ
        case tone              // ่ ้ ๊ ๋
        case silencer          // ์ - rides on top of whatever came before ("ธุ์")
        case digit
        case other
    }

    static func classify(_ scalar: Unicode.Scalar) -> Class {
        switch scalar.value {
        case 0x0E01...0x0E23, 0x0E25, 0x0E27...0x0E2E: return .consonant
        case 0x0E24, 0x0E26: return .consonant          // ฤ ฦ behave as onsets
        case 0x0E40...0x0E44: return .leadingVowel
        case 0x0E30, 0x0E32, 0x0E33, 0x0E45, 0x0E46, 0x0E2F: return .followingVowel
        case 0x0E31, 0x0E34...0x0E37, 0x0E47, 0x0E4D, 0x0E4E: return .aboveVowel
        case 0x0E4C: return .silencer
        case 0x0E38, 0x0E39, 0x0E3A: return .belowVowel
        case 0x0E48...0x0E4B: return .tone
        case 0x0E50...0x0E59: return .digit
        default: return .other
        }
    }

    /// Number of positions that cannot occur in real Thai.
    public static func violations(in text: String) -> Int {
        let classes = text.unicodeScalars.map(classify)
        guard !classes.isEmpty else { return 0 }
        var count = 0

        // A word cannot open with a mark that must attach to something.
        switch classes[0] {
        case .aboveVowel, .belowVowel, .tone, .followingVowel, .silencer: count += 1
        default: break
        }

        for i in 1..<classes.count {
            let previous = classes[i - 1], current = classes[i]
            switch (previous, current) {
            case (.tone, .tone),
                 (.aboveVowel, .aboveVowel),
                 (.belowVowel, .belowVowel),
                 (.tone, .aboveVowel), (.tone, .belowVowel),
                 (.leadingVowel, .aboveVowel), (.leadingVowel, .belowVowel),
                 (.leadingVowel, .tone), (.leadingVowel, .leadingVowel),
                 (.followingVowel, .tone), (.followingVowel, .aboveVowel), (.followingVowel, .belowVowel),
                 (.aboveVowel, .belowVowel), (.belowVowel, .aboveVowel),
                 (.silencer, .silencer), (.leadingVowel, .silencer), (.followingVowel, .silencer):
                count += 1
            default:
                break
            }
        }
        return count
    }

    /// Does the text carry any vowel, tone mark or leading vowel? Thai words of
    /// any length almost always do; a long run of bare consonants is a sign the
    /// keys were meant for another language.
    public static func hasVowelOrTone(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch classify(scalar) {
            case .leadingVowel, .followingVowel, .aboveVowel, .belowVowel, .tone: true
            default: false
            }
        }
    }

    public static func containsThai(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x0E00...0x0E7F).contains(Int($0.value)) }
    }
}
