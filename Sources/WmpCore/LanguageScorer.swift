import AppKit
import Foundation

/// How much a chunk of text looks like real Thai / real English, on 0...1.
public final class LanguageScorer {
    private var thaiWords: Set<String> = []
    private var englishWords: Set<String> = []
    /// Words that turn up in the system's own English UI: a stand-in for "words
    /// people actually type", which /usr/share/dict/words cannot tell apart from
    /// its own obscurities.
    private var commonEnglishWords: Set<String> = []
    /// Beginnings of real words, for judging a word that is still being typed.
    private var thaiPrefixes: Set<String> = []
    private var englishPrefixes: Set<String> = []
    private var spellCache: [String: Bool] = [:]
    private let tokenizerLocale = Locale(identifier: "th_TH") as CFLocale
    /// Past this length a prefix is distinctive enough; storing more only costs memory.
    private let maximumPrefixLength = 8

    public init(thaiWordListURL: URL? = nil, commonEnglishURL: URL? = nil) {
        self.thaiWordListURL = thaiWordListURL ?? WordListBuilder.thaiListURL
        self.commonEnglishURL = commonEnglishURL ?? WordListBuilder.englishListURL
        reload()
    }

    private let thaiWordListURL: URL
    private let commonEnglishURL: URL

    /// Re-reads the lists from disk. Called after the first-launch build so the
    /// running app picks them up without a restart.
    public func reload() {
        thaiWords = []
        thaiPrefixes = []
        commonEnglishWords = []
        loadThai(thaiWordListURL)
        if englishWords.isEmpty { loadEnglish() }
        loadCommonEnglish(commonEnglishURL)
    }

    private func loadCommonEnglish(_ url: URL?) {
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        commonEnglishWords = Set(text.split(separator: "\n").map(String.init))
    }

    /// Common enough to be worth acting on when the evidence is otherwise thin.
    public func isCommonEnglishWord(_ word: String) -> Bool {
        commonEnglishWords.contains(word.lowercased())
    }

    private func loadThai(_ url: URL?) {
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        thaiWords = Set(text.split(separator: "\n").map(String.init))
        for word in thaiWords {
            addPrefixes(of: word, to: &thaiPrefixes)
        }
    }

    private func loadEnglish() {
        for path in ["/usr/share/dict/words"] {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") where line.count > 1 {
                let word = line.lowercased()
                englishWords.insert(word)
                addPrefixes(of: word, to: &englishPrefixes)
            }
        }
    }

    private func addPrefixes(of word: String, to set: inout Set<String>) {
        // Only prefixes of words long enough to be worth predicting.
        guard word.count >= 3 else { return }
        var prefix = ""
        for (index, character) in word.enumerated() {
            prefix.append(character)
            guard index >= 2 else { continue }
            set.insert(prefix)
            if index + 1 >= maximumPrefixLength { break }
        }
    }

    /// Is this the start of a Thai word we know, with more to come?
    public func isThaiPrefix(_ text: String) -> Bool {
        thaiPrefixes.contains(text)
    }

    public func isThaiWord(_ text: String) -> Bool {
        thaiWords.contains(text)
    }

    public func isEnglishPrefix(_ text: String) -> Bool {
        englishPrefixes.contains(text.lowercased())
    }

    public var isReady: Bool { !thaiWords.isEmpty && !englishWords.isEmpty }

    // MARK: - Thai

    private func thaiTokens(_ text: String) -> [String] {
        let cf = text as CFString
        let tokenizer = CFStringTokenizerCreate(
            nil, cf, CFRangeMake(0, CFStringGetLength(cf)),
            kCFStringTokenizerUnitWordBoundary, tokenizerLocale
        )
        var out: [String] = []
        let ns = text as NSString
        while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            out.append(ns.substring(with: NSRange(location: range.location, length: range.length)))
        }
        return out
    }

    /// Longest run of characters that forms a Thai word we actually know.
    /// A real Thai word in the text is the strongest reason to leave it alone.
    public func longestKnownThaiToken(_ text: String) -> Int {
        thaiTokens(text).filter { thaiWords.contains($0) }.map(\.count).max() ?? 0
    }

    /// Segmentation with a known/unknown flag, for `--score` debugging.
    public func explainThai(_ text: String) -> [(token: String, known: Bool)] {
        thaiTokens(text).map { ($0, thaiWords.contains($0)) }
    }

    public func thaiScore(_ text: String) -> Double {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, ThaiOrthography.containsThai(trimmed) else { return 0 }
        // Any structural violation means this is not Thai anybody meant to type.
        guard ThaiOrthography.violations(in: trimmed) == 0 else { return 0 }

        // ICU segments by its own dictionary; if the whole thing is a word we
        // know, that beats however it chose to chop it up.
        if thaiWords.contains(trimmed) { return 1 }

        let tokens = thaiTokens(trimmed)
        guard !tokens.isEmpty else { return 0 }
        var known = 0, total = 0
        for token in tokens {
            let length = token.count
            total += length
            if thaiWords.contains(token) {
                known += length
            } else if length == 1, ThaiOrthography.containsThai(token) {
                // Single leftover characters are neither evidence for nor against.
                total -= length
            }
        }
        guard total > 0 else { return 0 }
        return Double(known) / Double(total)
    }

    // MARK: - Latin

    public func isEnglishWord(_ word: String) -> Bool {
        // NSSpellChecker finds no misspelling in "-v[" or in Thai text, because
        // it has no letters to judge. Insist on real letters first.
        guard word.count >= 2, word.allSatisfy({ $0.isLetter && $0.isASCII || $0 == "'" }) else { return false }
        let lower = word.lowercased()
        if englishWords.contains(lower) { return true }
        if let cached = spellCache[lower] { return cached }
        let range = NSSpellChecker.shared.checkSpelling(
            of: lower, startingAt: 0, language: "en", wrap: false,
            inSpellDocumentWithTag: 0, wordCount: nil
        )
        let ok = range.location == NSNotFound
        spellCache[lower] = ok
        return ok
    }

    /// Could a person read this out loud as English, whether or not it is in any
    /// dictionary? Names, slang and brand names are readable; "l;ylfu" and
    /// "8iy[" are not.
    ///
    /// This is the "unreadable in the language I am typing" test: it lets the
    /// tool act on words no word list will ever contain.
    public func isReadableLatin(_ text: String) -> Bool {
        // Judge the letters, not the punctuation: "main.swift" and "v2.1" are
        // things people type on purpose, and calling them unreadable would invite
        // the tool to convert filenames and version numbers into Thai.
        let chunks = text.split(whereSeparator: { !$0.isLetter }).map(String.init).filter { $0.count >= 3 }
        if chunks.count > 1 || (chunks.count == 1 && chunks[0] != text) {
            return chunks.allSatisfy(isReadableLatin)
        }
        guard let word = chunks.first, word == text else { return false }
        let lower = word.lowercased()
        guard lower.allSatisfy({ $0.isASCII }) else { return false }
        let vowels = Set("aeiouy")
        guard lower.contains(where: { vowels.contains($0) }) else { return false }

        // English tolerates "strengths" but not five consonants in a row, and a
        // word is not readable if it is nearly all vowels either.
        var consonantRun = 0, vowelRun = 0
        for character in lower {
            if vowels.contains(character) {
                vowelRun += 1; consonantRun = 0
            } else {
                consonantRun += 1; vowelRun = 0
            }
            if consonantRun > 4 || vowelRun > 3 { return false }
        }
        let vowelCount = lower.filter { vowels.contains($0) }.count
        return Double(vowelCount) / Double(lower.count) >= 0.2
    }

    /// The Thai equivalent: spellable, and not a pile of consonants with no
    /// vowel in sight.
    public func isReadableThai(_ text: String) -> Bool {
        // Every character has to be Thai: a stray "/" or "_" means these keys
        // were never a Thai word.
        guard text.unicodeScalars.allSatisfy({ (0x0E00...0x0E7F).contains(Int($0.value)) }),
              ThaiOrthography.violations(in: text) == 0 else { return false }
        return ThaiOrthography.hasVowelOrTone(text) || text.unicodeScalars.count <= 4
    }

    public func latinScore(_ text: String) -> Double {
        let words = text.split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)
        guard !words.isEmpty else { return 0 }
        var known = 0, total = 0
        for word in words {
            let length = word.count
            if length <= 2 {
                // "a", "I", "ok", "jk" - too small to be evidence either way,
                // and they turn up inside gibberish often enough to mislead.
                continue
            }
            total += length
            if isEnglishWord(word) { known += length }
        }
        // No word of two letters or more: nothing here says "English".
        guard total > 0 else { return 0 }
        return Double(known) / Double(total)
    }

    public func score(_ text: String, as script: Script) -> Double {
        script == .thai ? thaiScore(text) : latinScore(text)
    }
}
