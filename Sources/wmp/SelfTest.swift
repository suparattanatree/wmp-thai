import Foundation
import WmpCore

/// Replays realistic wrong-layout typing through the real decision path and
/// prints what would happen. Needs no Accessibility permission, so it is the
/// fastest way to judge whether the thresholds are behaving.
///
///   swift run wmp --selftest
enum SelfTest {
    /// Words that should be rescued: what the user meant, and the layout they
    /// forgot to switch to.
    static let shouldFix: [(intended: String, script: Script)] = [
        ("สวัสดี", .thai), ("ขอบคุณ", .thai), ("ครับ", .thai), ("ทำงาน", .thai),
        ("ประเทศ", .thai), ("โทรศัพท์", .thai), ("ข้อมูล", .thai), ("ตั้งค่า", .thai),
        ("รูปภาพ", .thai), ("เรียบร้อย", .thai),
        ("hello", .latin), ("thanks", .latin), ("keyboard", .latin), ("project", .latin),
        ("meeting", .latin), ("password", .latin), ("computer", .latin), ("language", .latin),
    ]

    /// Correctly typed words that must be left alone.
    static let shouldLeaveAlone: [(text: String, script: Script)] = [
        ("สวัสดี", .thai), ("ขอบคุณ", .thai), ("ครับ", .thai), ("อะไร", .thai), ("นา", .thai),
        ("ไม่", .thai), ("ได้", .thai), ("แต่", .thai), ("การ", .thai), ("ผม", .thai),
        ("เอ็มมา", .thai), ("ทดสอบ", .thai), ("ตอนนี้", .thai),
        ("hello", .latin), ("thanks", .latin), ("keyboard", .latin), ("ok", .latin), ("git", .latin),
        ("npm", .latin), ("async", .latin), ("docker", .latin), ("swift", .latin), ("config", .latin),
        ("asdf", .latin), ("qwerty", .latin), ("xyz123", .latin), ("v2.1", .latin),
        ("https://example.com", .latin), ("user@mail.com", .latin), ("main.swift", .latin),
        ("Bv2NitLJJbY", .latin), ("2026-08-13", .latin),
    ]

    static func run() {
        guard let layouts = LayoutPair() else {
            print("No Latin+Thai layout pair installed. Add Thai in System Settings > Keyboard.")
            return
        }
        let scorer = LanguageScorer()
        let corrector = Corrector(layouts: layouts, scorer: scorer)
        print("layouts: \(layouts.latin.localizedName) ↔ \(layouts.thai.localizedName)")
        print("scorer ready: \(scorer.isReady)\n")

        var passed = 0, failed = 0

        print("— wrong layout, should be fixed —")
        for case_ in shouldFix {
            guard let strokes = layouts.strokes(for: case_.intended, on: case_.script) else {
                print("  ??  \(case_.intended): not typeable on that layout"); failed += 1; continue
            }
            let wrongScript: Script = case_.script == .thai ? .latin : .thai
            let appeared = layouts.render(strokes, as: wrongScript)
            var buffer = TypingBuffer()
            for (stroke, character) in zip(strokes, appeared.unicodeScalars) {
                buffer.append(keycode: stroke.keycode, shift: stroke.shift, character: String(character))
            }
            let result = corrector.evaluate(buffer)
            let ok = result?.replacement == case_.intended
            ok ? (passed += 1) : (failed += 1)
            let arrow = result.map { "→ \($0.replacement) [\(fmt($0.originalScore))/\(fmt($0.replacementScore))]" } ?? "→ (no fix)"
            print("  \(ok ? "ok " : "MISS") \(appeared) \(arrow)   want \(case_.intended)")
        }

        print("\n— typed correctly, must be left alone —")
        for case_ in shouldLeaveAlone {
            guard let strokes = layouts.strokes(for: case_.text, on: case_.script) else { continue }
            var buffer = TypingBuffer()
            for (stroke, character) in zip(strokes, case_.text.unicodeScalars) {
                buffer.append(keycode: stroke.keycode, shift: stroke.shift, character: String(character))
            }
            let result = corrector.evaluate(buffer)
            let ok = result == nil
            ok ? (passed += 1) : (failed += 1)
            let note = result.map { "WOULD MANGLE → \($0.replacement) [\(fmt($0.originalScore))/\(fmt($0.replacementScore))]" } ?? "left alone"
            print("  \(ok ? "ok " : "BAD ") \(case_.text): \(note)")
        }

        print("\n— mid-word switching: how many keys before it catches on —")
        for case_ in shouldFix {
            guard let strokes = layouts.strokes(for: case_.intended, on: case_.script) else { continue }
            let wrongScript: Script = case_.script == .thai ? .latin : .thai
            let appeared = layouts.render(strokes, as: wrongScript)
            var buffer = TypingBuffer()
            var firedAt: Int?
            for (index, pair) in zip(strokes, appeared.unicodeScalars).enumerated() {
                buffer.append(keycode: pair.0.keycode, shift: pair.0.shift, character: String(pair.1))
                if firedAt == nil, corrector.evaluatePrefix(buffer) != nil { firedAt = index + 1 }
            }
            let total = strokes.count
            if let firedAt {
                print("  \(case_.intended): switched after \(firedAt)/\(total) keys")
            } else {
                print("  \(case_.intended): only at the space bar")
            }
        }

        print("\n— mid-word switching must never fire on correct typing —")
        for case_ in shouldLeaveAlone {
            guard let strokes = layouts.strokes(for: case_.text, on: case_.script) else { continue }
            var buffer = TypingBuffer()
            var firedAt: String?
            for pair in zip(strokes, case_.text.unicodeScalars) {
                buffer.append(keycode: pair.0.keycode, shift: pair.0.shift, character: String(pair.1))
                if firedAt == nil, let hit = corrector.evaluatePrefix(buffer) {
                    firedAt = "\(buffer.typed) → \(hit.replacement)"
                }
            }
            let ok = firedAt == nil
            ok ? (passed += 1) : (failed += 1)
            print("  \(ok ? "ok " : "BAD ") \(case_.text): \(firedAt ?? "never fired")")
        }

        // The replayer sends one backspace per scalar, so a key press that does
        // not produce exactly one scalar would make it delete the wrong amount.
        print("\n— one key press must produce exactly one character —")
        var keyMismatches: [String] = []
        for (script, source) in [(Script.thai, shouldFix.map(\.intended)), (.latin, shouldLeaveAlone.map(\.text))] {
            for word in source {
                guard let strokes = layouts.strokes(for: word, on: script) else { continue }
                for target in [Script.thai, Script.latin] {
                    let rendered = layouts.render(strokes, as: target)
                    if rendered.unicodeScalars.count != strokes.count {
                        keyMismatches.append("\(word) as \(target.rawValue): \(strokes.count) keys → \(rendered.unicodeScalars.count) chars")
                    }
                }
            }
        }
        if keyMismatches.isEmpty {
            passed += 1
            print("  ok  every key press renders to one character in both layouts")
        } else {
            failed += 1
            for mismatch in keyMismatches.prefix(5) { print("  BAD \(mismatch)") }
        }

        // Turning a direction off has to silence it completely, in both the
        // mid-word and the space bar path.
        print("\n— one direction at a time —")
        for (allowed, label) in [(Set<Script>([.thai]), "ABC → ก ข ค"), (Set<Script>([.latin]), "ก ข ค → ABC")] {
            corrector.allowedTargets = allowed
            var wrongWay = 0, rightWay = 0
            for case_ in shouldFix {
                guard let strokes = layouts.strokes(for: case_.intended, on: case_.script) else { continue }
                let wrongScript: Script = case_.script == .thai ? .latin : .thai
                let appeared = layouts.render(strokes, as: wrongScript)
                var buffer = TypingBuffer()
                var fired = false
                for pair in zip(strokes, appeared.unicodeScalars) {
                    buffer.append(keycode: pair.0.keycode, shift: pair.0.shift, character: String(pair.1))
                    if corrector.evaluatePrefix(buffer) != nil { fired = true }
                }
                if corrector.evaluate(buffer) != nil { fired = true }
                guard fired else { continue }
                allowed.contains(case_.script) ? (rightWay += 1) : (wrongWay += 1)
            }
            let ok = wrongWay == 0 && rightWay > 0
            ok ? (passed += 1) : (failed += 1)
            print("  \(ok ? "ok " : "BAD ") \(label): แก้ \(rightWay) คำ, หลุดทิศทางอื่น \(wrongWay) คำ")
        }
        corrector.allowedTargets = [.thai, .latin]

        // Converting a selection is pure character mapping, so it has to survive
        // a round trip: flip it and flip it back and nothing may be lost.
        print("\n— converting a selection —")
        // Single-script selections flip whole: the user picked them on purpose.
        let wholeFlips = [
            "l;ylfu8iy[ ,u-hv8;k,",
            "สวัสดีครับ มีข้อความ",
            "hello world 123",
        ]
        for text in wholeFlips {
            let target: Script = ThaiOrthography.containsThai(text) ? .latin : .thai
            let converted = corrector.convertSelection(text, layouts: layouts)
            let back = layouts.convertKeepingUnknown(text: converted, to: target == .thai ? .latin : .thai)
            let ok = back == text && converted != text
            ok ? (passed += 1) : (failed += 1)
            print("  \(ok ? "ok " : "BAD ") \(text)  →  \(converted)")
        }

        // Mixed selections: only the words that are actually in the wrong layout.
        let mixed: [(text: String, want: String)] = [
            ("l;ylfu hello", "สวัสดี hello"),
            ("ทดสอบ hello ผสมกัน 42", "ทดสอบ hello ผสมกัน 42"),
            ("ผม ้ำสสน แล้ว", "ผม hello แล้ว"),
        ]
        for case_ in mixed {
            let converted = corrector.convertSelection(case_.text, layouts: layouts)
            let ok = converted == case_.want
            ok ? (passed += 1) : (failed += 1)
            print("  \(ok ? "ok " : "BAD ") \(case_.text)  →  \(converted)   want \(case_.want)")
        }

        bulkFalsePositiveCheck(layouts: layouts, corrector: corrector)

        print("\n\(passed) passed, \(failed) failed")
    }

    /// Types thousands of correctly spelled words, one key at a time, and counts
    /// how often the tool would have interfered. The number that matters is zero:
    /// this runs against real vocabulary, not the handful of cases above.
    private static func bulkFalsePositiveCheck(layouts: LayoutPair, corrector: Corrector) {
        func words(from path: String, stride: Int, limit: Int) -> [String] {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
            let all = text.split(separator: "\n").map(String.init)
            return Swift.stride(from: 0, to: all.count, by: stride).prefix(limit).map { all[$0] }
        }

        let thaiList = WordListBuilder.thaiListURL.path
        let samples: [(script: Script, words: [String])] = [
            (.thai, words(from: thaiList, stride: 7, limit: 3000)),
            (.latin, words(from: "/usr/share/dict/words", stride: 40, limit: 3000)),
        ]

        print("\n— bulk check on real vocabulary —")
        for sample in samples {
            var tested = 0, midWord = 0, atSpace = 0
            var examples: [String] = []
            for word in sample.words where word.count >= 3 {
                guard let strokes = layouts.strokes(for: word, on: sample.script) else { continue }
                tested += 1
                var buffer = TypingBuffer()
                var fired = false
                for pair in zip(strokes, word.unicodeScalars) {
                    buffer.append(keycode: pair.0.keycode, shift: pair.0.shift, character: String(pair.1))
                    if !fired, let hit = corrector.evaluatePrefix(buffer) {
                        fired = true
                        midWord += 1
                        if examples.count < 5 { examples.append("mid-word \(buffer.typed) → \(hit.replacement)") }
                    }
                }
                if let hit = corrector.evaluate(buffer) {
                    atSpace += 1
                    if examples.count < 5 { examples.append("at space \(word) → \(hit.replacement)") }
                }
            }
            let label = sample.script == .thai ? "Thai" : "English"
            print("  \(label): \(tested) words, \(midWord) mid-word false switches, \(atSpace) false fixes at the space bar")
            for example in examples { print("     \(example)") }
        }
    }

    private static func fmt(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

/// `--score <text>` prints why a string scored the way it did.
enum ScoreDebug {
    static func run(_ text: String) {
        let scorer = LanguageScorer()
        print("thai  \(String(format: "%.2f", scorer.thaiScore(text)))  violations=\(ThaiOrthography.violations(in: text))")
        for (token, known) in scorer.explainThai(text) {
            print("   \(known ? "known  " : "unknown") \(token)")
        }
        print("latin \(String(format: "%.2f", scorer.latinScore(text)))")
        print("thaiPrefix=\(scorer.isThaiPrefix(text)) thaiWord=\(scorer.isThaiWord(text)) englishPrefix=\(scorer.isEnglishPrefix(text)) englishWord=\(scorer.isEnglishWord(text))")
    }
}

/// `--try <text>` prints the same verdicts the "ลองดู" pane shows.
enum TryDebug {
    static func run(_ text: String) {
        guard let layouts = LayoutPair() else { return }
        let corrector = Corrector(layouts: layouts, scorer: LanguageScorer())
        for result in corrector.simulate(text) {
            if let at = result.midWordAt, let midWord = result.midWord {
                print("\(result.word) → \(result.outcome)   สลับตั้งแต่ตัวที่ \(at)/\(result.keys) (ตอนนั้น \(midWord.replacement))")
            } else if result.atSpace != nil {
                print("\(result.word) → \(result.outcome)   แก้ตอนเคาะ space")
            } else {
                print("\(result.word)   ไม่แตะ")
            }
        }
    }
}

/// `--typo <text>` renders what the text looks like when the layout was
/// forgotten, then runs the verdicts on it. Saves hand-building wrong-layout
/// strings, which is easy to get wrong.
enum TypoDebug {
    static func run(_ text: String) {
        guard let layouts = LayoutPair() else { return }
        let corrector = Corrector(layouts: layouts, scorer: LanguageScorer())
        for piece in text.split(whereSeparator: \.isWhitespace) {
            let word = String(piece)
            let intended: Script = ThaiOrthography.containsThai(word) ? .thai : .latin
            guard let strokes = layouts.strokes(for: word, on: intended) else {
                print("\(word): พิมพ์บนเลย์เอาต์นั้นไม่ได้"); continue
            }
            let wrong: Script = intended == .thai ? .latin : .thai
            let appeared = layouts.render(strokes, as: wrong)
            let verdicts = corrector.simulate(appeared)
            let outcome = verdicts.first.map { result -> String in
                if let at = result.midWordAt {
                    return "→ \(result.outcome) (สลับที่ตัวที่ \(at)/\(result.keys))"
                }
                return result.atSpace != nil ? "→ \(result.outcome) (ตอนเคาะ space)" : "ไม่แตะ"
            } ?? "ไม่แตะ"
            let ok = verdicts.first?.outcome == word
            print("\(ok ? "ok  " : "MISS") \(word) พิมพ์ผิดเป็น \(appeared)  \(outcome)")
        }
    }
}

/// `--sweep` answers "how many words does the list actually need".
///
/// Truncates the Thai list to the N most frequent words, then measures two
/// things at each size: how many wrong-layout words get rescued, and how often
/// correctly typed Thai gets mangled. The interesting number is where both
/// curves flatten.
enum WordListSweep {
    static func run() {
        guard let layouts = LayoutPair() else { return }
        FileHandle.standardError.write("อ่านความถี่คำจากเครื่อง...\n".data(using: .utf8)!)
        let ranked = WordListBuilder.thaiWordFrequencies()
        let totalOccurrences = ranked.reduce(0) { $0 + $1.count }
        guard !ranked.isEmpty else { print("no words found"); return }

        // Words people actually type follow the same distribution as the corpus,
        // so weight the test set by frequency rather than sampling uniformly.
        let sample = Array(ranked.prefix(4000)).filter { $0.word.count >= 3 }

        print("คำทั้งหมดที่เจอ: \(ranked.count) คำ (\(totalOccurrences) ครั้ง)")
        print("\nขนาดคลัง   ครอบคลุมข้อความ   จับคำผิดภาษาได้   แก้คำถูกผิดพลาด")

        let sizes = [0, 200, 500, 1000, 2000, 5000, 10_000, ranked.count]
        let directory = FileManager.default.temporaryDirectory
        for size in sizes {
            let slice = Array(ranked.prefix(size))
            let covered = slice.reduce(0) { $0 + $1.count }
            let coverage = Double(covered) / Double(totalOccurrences) * 100

            let url = directory.appendingPathComponent("wmp-sweep-\(size).txt")
            try? slice.map(\.word).joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)

            let scorer = LanguageScorer(thaiWordListURL: url)
            let corrector = Corrector(layouts: layouts, scorer: scorer)

            var caught = 0, tested = 0, mangled = 0
            for entry in sample {
                guard let strokes = layouts.strokes(for: entry.word, on: .thai) else { continue }
                tested += 1

                // Typed on the Latin layout by mistake: should be rescued.
                let appeared = layouts.render(strokes, as: .latin)
                var wrong = TypingBuffer()
                for pair in zip(strokes, appeared.unicodeScalars) {
                    wrong.append(keycode: pair.0.keycode, shift: pair.0.shift, character: String(pair.1))
                    if corrector.evaluatePrefix(wrong) != nil { break }
                }
                if corrector.evaluatePrefix(wrong) != nil || corrector.evaluate(wrong) != nil { caught += 1 }

                // Typed correctly: must be left alone.
                var right = TypingBuffer()
                var fired = false
                for pair in zip(strokes, entry.word.unicodeScalars) {
                    right.append(keycode: pair.0.keycode, shift: pair.0.shift, character: String(pair.1))
                    if corrector.evaluatePrefix(right) != nil { fired = true }
                }
                if fired || corrector.evaluate(right) != nil { mangled += 1 }
            }

            let label = size == ranked.count ? "ทั้งหมด" : "\(size)"
            print(String(format: "%-10@ %13.1f%% %15.1f%% %15.2f%%",
                         label as NSString, coverage,
                         Double(caught) / Double(tested) * 100,
                         Double(mangled) / Double(tested) * 100))
        }
        print("\nวัดกับคำไทย \(sample.count) คำ ที่คนพิมพ์บ่อยที่สุด")
    }
}
