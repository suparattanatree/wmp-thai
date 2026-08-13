import Foundation

public struct Correction: Sendable {
    public let original: String
    public let replacement: String
    public let targetScript: Script
    public let originalScore: Double
    public let replacementScore: Double

    public init(original: String, replacement: String, targetScript: Script,
                originalScore: Double, replacementScore: Double) {
        self.original = original
        self.replacement = replacement
        self.targetScript = targetScript
        self.originalScore = originalScore
        self.replacementScore = replacementScore
    }
}

public struct CorrectorThresholds: Sendable {
    /// The other layout has to look genuinely like a word.
    public var minimumReplacementScore: Double = 0.75
    /// What was typed has to look genuinely like nothing.
    public var maximumOriginalScore: Double = 0.25
    /// And the gap has to be wide, so ambiguous pairs are left alone.
    public var minimumGap: Double = 0.5
    public var minimumLength: Int = 3
    /// Mid-word switching needs a few keys before there is anything to judge.
    public var minimumPrefixLength: Int = 3
    /// Long runs are identifiers, tokens and URLs, not forgotten layouts.
    public var maximumLength: Int = 40

    public init() {}
}

/// Decides whether a finished word was typed on the wrong layout.
/// Conservative by design: ambiguous pairs are left alone.
public final class Corrector {
    private let layouts: LayoutPair
    private let scorer: LanguageScorer
    public var thresholds: CorrectorThresholds
    /// Which way round corrections are allowed to go. Someone who only ever
    /// forgets one of the two switches can turn the other direction off and stop
    /// paying for its mistakes entirely.
    public var allowedTargets: Set<Script> = [.thai, .latin]
    /// When what was typed cannot be read in the language it landed in, act on
    /// the other reading even if no word list confirms it. This is what catches
    /// names, slang and anything else a dictionary will never hold.
    public var guessWhenUnreadable = true

    public init(layouts: LayoutPair, scorer: LanguageScorer, thresholds: CorrectorThresholds = .init()) {
        self.layouts = layouts
        self.scorer = scorer
        self.thresholds = thresholds
    }

    public func evaluate(_ buffer: TypingBuffer) -> Correction? {
        guard buffer.count >= thresholds.minimumLength,
              buffer.count <= thresholds.maximumLength,
              let typedScript = buffer.script
        else { return nil }
        let target: Script = typedScript == .thai ? .latin : .thai
        guard allowedTargets.contains(target) else { return nil }

        let original = buffer.typed
        let replacement = layouts.render(buffer.strokes, as: target)
        guard !replacement.isEmpty, replacement != original else { return nil }

        let originalScore = scorer.score(original, as: typedScript)
        let replacementScore = scorer.score(replacement, as: target)

        // Either the other reading is a known word, or what was typed is simply
        // unreadable where it landed while the other reading is not.
        let unreadableHere = guessWhenUnreadable && isUnreadable(original, as: typedScript)
            && isReadable(replacement, as: target)
        guard replacementScore >= thresholds.minimumReplacementScore || unreadableHere else { return nil }

        // The two directions need different evidence.
        switch typedScript {
        case .latin:
            // Meant Thai. English gibberish is unmistakable, so comparing the two
            // readings is enough.
            guard unreadableHere || (originalScore <= thresholds.maximumOriginalScore
                                     && replacementScore - originalScore >= thresholds.minimumGap)
            else { return nil }

        case .thai:
            // Meant English. Coverage lies here: "good for" lands as "เนนก ดนพ",
            // which ICU splits into syllables the dictionary knows. What separates
            // the cases is a substantial Thai word, and a common English reading.
            if ThaiOrthography.violations(in: original) > 0 {
                break   // Thai that breaks spelling rules was never Thai
            }
            guard isPlausiblyTyped(replacement),
                  scorer.isCommonEnglishWord(replacement) || (unreadableHere && scorer.isReadableLatin(replacement)),
                  scorer.longestKnownThaiToken(original) <= 2
            else { return nil }
        }

        return Correction(
            original: original, replacement: replacement, targetScript: target,
            originalScore: originalScore, replacementScore: replacementScore
        )
    }

    /// Decides mid-word, so the keyboard can switch while typing continues.
    /// Stricter than `evaluate`: interrupting a word costs more than tidying one.
    public func evaluatePrefix(_ buffer: TypingBuffer) -> Correction? {
        guard buffer.count >= thresholds.minimumPrefixLength,
              buffer.count <= thresholds.maximumLength,
              let typedScript = buffer.script
        else { return nil }
        let target: Script = typedScript == .thai ? .latin : .thai
        guard allowedTargets.contains(target) else { return nil }

        let original = buffer.typed
        let replacement = layouts.render(buffer.strokes, as: target)
        guard !replacement.isEmpty, replacement != original else { return nil }

        switch target {
        case .thai:
            // Latin keys, Thai intent. The Thai reading has to be spellable and
            // the actual start of a word, and the Latin side has to look like
            // nothing anyone types on purpose.
            guard ThaiOrthography.violations(in: replacement) == 0 else { return nil }
            guard scorer.isThaiPrefix(replacement) || scorer.isThaiWord(replacement) else { return nil }
            guard !scorer.isEnglishPrefix(original), !scorer.isEnglishWord(original) else { return nil }
            // A symbol or a stray capital in the middle of a "word" is the
            // giveaway; without one, wait until the Thai reading is a full word.
            guard hasWrongLayoutTell(original) || scorer.isThaiWord(replacement) else { return nil }

        case .latin:
            // Thai keys, English intent.
            guard scorer.isEnglishPrefix(replacement) || scorer.isEnglishWord(replacement) else { return nil }
            if ThaiOrthography.violations(in: original) == 0 {
                // No broken spelling to lean on, so demand a whole common word:
                // a prefix like "dita" matches Thai fragments too often.
                // A real Thai word inside means someone is typing Thai and is
                // not done yet: "ทำหน" on the way to "ทำหน้าที่".
                guard buffer.count >= thresholds.minimumPrefixLength + 1,
                      isPlausiblyTyped(replacement),
                      scorer.isCommonEnglishWord(replacement),
                      !scorer.isThaiPrefix(original), !scorer.isThaiWord(original),
                      scorer.longestKnownThaiToken(original) == 0
                else { return nil }
            }
        }

        return Correction(original: original, replacement: replacement, targetScript: target,
                          originalScore: 0, replacementScore: 1)
    }

    private func isUnreadable(_ text: String, as script: Script) -> Bool {
        script == .thai ? !scorer.isReadableThai(text) : !scorer.isReadableLatin(text)
    }

    private func isReadable(_ text: String, as script: Script) -> Bool {
        script == .thai ? scorer.isReadableThai(text) : scorer.isReadableLatin(text)
    }

    /// Letters only, cased the way people type. Thai shift keys render as
    /// capitals mid-word ("ทฤษฎ" becomes "mAKE"), which English never is.
    private func isPlausiblyTyped(_ text: String) -> Bool {
        guard text.allSatisfy({ $0.isLetter }) else { return false }
        return !text.dropFirst().contains(where: \.isUppercase)
    }

    /// Marks that no one types inside an English word: punctuation, digits, or a
    /// capital after the first letter. On the Thai layout these keys are letters.
    private func hasWrongLayoutTell(_ text: String) -> Bool {
        for (index, character) in text.enumerated() {
            if character.isLetter {
                if index > 0, character.isUppercase { return true }
                continue
            }
            if character == "'" || character == "-" { continue }
            return true
        }
        return false
    }

    /// What would happen to text, word by word. Drives the "try it" pane.
    public struct Simulation: Identifiable, Sendable {
        public let id = UUID()
        public let word: String
        public let keys: Int
        /// Where mid-word switching would kick in, counted in key presses.
        public let midWordAt: Int?
        public let midWord: Correction?
        public let atSpace: Correction?
        /// What ends up on screen once the whole word is typed. After a mid-word
        /// switch the remaining keys land in the new script, so the outcome is
        /// the whole word converted, not the fragment that triggered it.
        public let outcome: String

        public var isTouched: Bool { midWord != nil || atSpace != nil }
    }

    public func simulate(_ text: String) -> [Simulation] {
        Corrector.words(in: text).compactMap { word in
            let script: Script = ThaiOrthography.containsThai(word) ? .thai : .latin
            guard let strokes = layouts.strokes(for: word, on: script) else { return nil }

            var buffer = TypingBuffer()
            var midWordAt: Int?
            var midWord: Correction?
            for (index, pair) in zip(strokes, word.unicodeScalars).enumerated() {
                buffer.append(keycode: pair.0.keycode, shift: pair.0.shift, character: String(pair.1))
                if midWordAt == nil, let hit = evaluatePrefix(buffer) {
                    midWordAt = index + 1
                    midWord = hit
                }
            }
            let atSpace = evaluate(buffer)
            let outcome: String
            if let midWord {
                outcome = layouts.render(strokes, as: midWord.targetScript)
            } else if let atSpace {
                outcome = atSpace.replacement
            } else {
                outcome = word
            }
            return Simulation(word: word, keys: strokes.count, midWordAt: midWordAt,
                              midWord: midWord, atSpace: atSpace, outcome: outcome)
        }
    }

    /// Flips a selection: all of it when it is one script, otherwise only the
    /// words that read better the other way. Whitespace is preserved.
    public func convertSelection(_ text: String, layouts: LayoutPair) -> String {
        // Judge word by word first. "l;ylfu hello" is all Latin characters, but
        // only half of it is a mistake, so looking at which script the text is
        // written in says nothing useful.
        let perWord = flippingWrongWords(in: text)
        if perWord != text { return perWord }

        // Nothing was obviously wrong. If the selection mixes real Thai with
        // real English, leave it: flipping it would break whichever half was
        // right. If it is all one script, the user asked for it - flip the lot.
        let hasThai = ThaiOrthography.containsThai(text)
        let hasLatin = text.contains { $0.isLetter && $0.isASCII }
        if hasThai, hasLatin { return text }
        let target: Script = hasThai ? .latin : .thai
        return layouts.convertKeepingUnknown(text: text, to: target)
    }

    private func flippingWrongWords(in text: String) -> String {
        var out = ""
        var run = ""
        func flushRun() {
            guard !run.isEmpty else { return }
            out += simulate(run).first?.outcome ?? run
            run = ""
        }
        for scalar in text.unicodeScalars {
            if Corrector.isWhitespace(scalar) {
                flushRun()
                out.unicodeScalars.append(scalar)
            } else {
                run.unicodeScalars.append(scalar)
            }
        }
        flushRun()
        return out
    }

    static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    /// Splits on scalars, not Characters: a Thai mark opening a word binds to
    /// the space before it, and Character splitting would eat it.
    static func words(in text: String) -> [String] {
        var words: [String] = []
        var current = ""
        for scalar in text.unicodeScalars {
            if isWhitespace(scalar) {
                if !current.isEmpty { words.append(current); current = "" }
            } else {
                current.unicodeScalars.append(scalar)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    /// Manual conversion (hotkey): flip the text regardless of scores.
    public func forceConvert(_ text: String) -> Correction? {
        let source: Script = ThaiOrthography.containsThai(text) ? .thai : .latin
        let target: Script = source == .thai ? .latin : .thai
        guard let converted = layouts.convert(text: text, to: target) else { return nil }
        return Correction(original: text, replacement: converted, targetScript: target,
                          originalScore: 0, replacementScore: 1)
    }
}
