import Compression
import Foundation

/// Builds the word lists from what is already on this Mac: the system Thai
/// dictionary, and the Thai and English strings every app ships for its UI.
///
/// Runs on the user's own machine rather than shipping the result, so nothing
/// derived from Apple's dictionaries is ever redistributed. Takes a few seconds
/// once, on first launch.
public enum WordListBuilder {
    public static let roots = ["/System/Library", "/System/Applications", "/Applications"]

    /// Where the built lists live: Application Support, not inside the app, so
    /// they survive updates and can be rebuilt without touching the bundle.
    public static var storageDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("wmp-thai", isDirectory: true)
    }

    public static var thaiListURL: URL { storageDirectory.appendingPathComponent("th_words.txt") }
    public static var englishListURL: URL { storageDirectory.appendingPathComponent("en_words.txt") }
    /// Words the user added by hand, or that the tool learned from being undone.
    public static var userListURL: URL { storageDirectory.appendingPathComponent("user_words.txt") }

    /// Lists we maintain in the repository and ship with the app, so vocabulary
    /// can be improved by an update rather than only by what a Mac happens to
    /// contain. Ours to redistribute, unlike anything harvested from the system.
    public static var curatedThaiURL: URL? { Bundle.module.url(forResource: "curated_th", withExtension: "txt") }
    public static var curatedEnglishURL: URL? { Bundle.module.url(forResource: "curated_en", withExtension: "txt") }

    /// Reads a word list, skipping comments and blank lines.
    public static func words(at url: URL?) -> [String] {
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    public static func addUserWord(_ word: String) {
        var existing = words(at: userListURL)
        let trimmed = word.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !existing.contains(trimmed) else { return }
        existing.append(trimmed)
        save(userWords: existing)
    }

    public static func removeUserWord(_ word: String) {
        save(userWords: words(at: userListURL).filter { $0 != word })
    }

    public static func save(userWords: [String]) {
        try? FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
        try? userWords.sorted().joined(separator: "\n").write(to: userListURL, atomically: true, encoding: .utf8)
    }

    public static var isBuilt: Bool {
        FileManager.default.fileExists(atPath: thaiListURL.path)
            && FileManager.default.fileExists(atPath: englishListURL.path)
    }

    /// Builds both lists and writes them. `progress` is called with a short line
    /// of what it is doing, for the status the settings window shows.
    ///
    /// `includeSystemDictionary` is off by default on purpose. Reading the
    /// macOS Thai dictionary means decoding an undocumented binary format and
    /// lifting the headwords out of content Apple licenses from a publisher.
    /// It stays on the user's machine, but it is the one part of this that sits
    /// in a legal grey area - and measurement says it barely matters: with UI
    /// strings alone the tool still catches even formal words like ทฤษฎี and
    /// ปรัชญา, because the readability rules do not need a dictionary.
    @discardableResult
    public static func build(includeSystemDictionary: Bool = false,
                             progress: ((String) -> Void)? = nil) throws -> (thai: Int, english: Int) {
        try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)

        var headwords: Set<String> = []
        if includeSystemDictionary {
            progress?("อ่านดิกชันนารีไทยของระบบ")
            headwords = dictionaryHeadwords()
        }

        progress?("อ่านข้อความในเครื่อง")
        let harvested = harvestInterfaceStrings()

        let thai = headwords.union(harvested.thai)
        let english = harvested.english
        try thai.sorted().joined(separator: "\n").write(to: thaiListURL, atomically: true, encoding: .utf8)
        try english.sorted().joined(separator: "\n").write(to: englishListURL, atomically: true, encoding: .utf8)
        progress?("เสร็จแล้ว")
        return (thai.count, english.count)
    }

    // MARK: - Sources

    static func isThai(_ scalar: Unicode.Scalar) -> Bool { (0x0E00...0x0E7F).contains(Int(scalar.value)) }
    static func hasThai(_ text: String) -> Bool { text.unicodeScalars.contains(where: isThai) }
    static func allThai(_ text: String) -> Bool { !text.isEmpty && text.unicodeScalars.allSatisfy(isThai) }

    static func stringsFileText(_ path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        if data.starts(with: Array("bplist".utf8)) {
            guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return nil }
            var parts: [String] = []
            func walk(_ any: Any) {
                switch any {
                case let dictionary as [String: Any]: dictionary.values.forEach(walk)
                case let array as [Any]: array.forEach(walk)
                case let string as String: parts.append(string)
                default: break
                }
            }
            walk(plist)
            return parts.joined(separator: "\n")
        }
        if let utf16 = String(data: data, encoding: .utf16), hasThai(utf16) { return utf16 }
        return String(data: data, encoding: .utf8)
    }

    /// Both languages in one pass over the disk, spread across cores.
    ///
    /// The naive version walked /Applications once per language and took over a
    /// minute; nobody waits that long on first launch. Listing paths is cheap,
    /// reading and tokenising thousands of files is not, so that part is what
    /// gets parallelised.
    static func harvestInterfaceStrings(minimumCount: Int = 3) -> (thai: Set<String>, english: Set<String>) {
        var thaiFiles: [String] = []
        var englishFiles: [String] = []
        for root in roots {
            guard let walker = FileManager.default.enumerator(atPath: root) else { continue }
            for case let relative as String in walker {
                guard relative.hasSuffix(".strings") || relative.hasSuffix(".stringsdict") else { continue }
                let path = root + "/" + relative
                if relative.contains("th.lproj/") {
                    thaiFiles.append(path)
                } else if relative.contains("en.lproj/") || relative.contains("English.lproj/") {
                    englishFiles.append(path)
                }
            }
        }

        var thaiCounts: [String: Int] = [:]
        var englishCounts: [String: Int] = [:]
        let lock = NSLock()

        func merge(_ local: [String: Int], into shared: inout [String: Int]) {
            lock.lock()
            for (word, count) in local { shared[word, default: 0] += count }
            lock.unlock()
        }

        let workers = max(2, ProcessInfo.processInfo.activeProcessorCount - 1)
        func distribute(_ files: [String], _ handle: @escaping (String, inout [String: Int]) -> Void,
                        into shared: inout [String: Int]) {
            guard !files.isEmpty else { return }
            let chunkSize = max(1, files.count / workers + 1)
            let chunks = stride(from: 0, to: files.count, by: chunkSize).map {
                Array(files[$0..<min($0 + chunkSize, files.count)])
            }
            var partials = [[String: Int]](repeating: [:], count: chunks.count)
            partials.withUnsafeMutableBufferPointer { buffer in
                DispatchQueue.concurrentPerform(iterations: chunks.count) { index in
                    var local: [String: Int] = [:]
                    for path in chunks[index] { handle(path, &local) }
                    buffer[index] = local
                }
            }
            for partial in partials { merge(partial, into: &shared) }
        }

        distribute(thaiFiles, { path, local in
            guard let text = stringsFileText(path), hasThai(text) else { return }
            let locale = Locale(identifier: "th_TH") as CFLocale
            let cf = text as CFString
            let tokenizer = CFStringTokenizerCreate(
                nil, cf, CFRangeMake(0, CFStringGetLength(cf)),
                kCFStringTokenizerUnitWordBoundary, locale
            )
            let ns = text as NSString
            while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
                let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
                let token = ns.substring(with: NSRange(location: range.location, length: range.length))
                if allThai(token), token.count >= 2 { local[token, default: 0] += 1 }
            }
        }, into: &thaiCounts)

        distribute(englishFiles, { path, local in
            guard let text = stringsFileText(path) else { return }
            for token in text.split(whereSeparator: { !$0.isLetter && $0 != "'" }) {
                let word = token.lowercased()
                guard word.count >= 2, word.allSatisfy({ $0.isASCII && $0.isLetter }) else { continue }
                local[word, default: 0] += 1
            }
        }, into: &englishCounts)

        return (Set(thaiCounts.filter { $0.value >= minimumCount }.keys),
                Set(englishCounts.filter { $0.value >= minimumCount }.keys))
    }

    /// Same harvest, but keeping how often each word appeared. Used to answer
    /// "how big does the list need to be" by measuring instead of guessing.
    public static func thaiWordFrequencies() -> [(word: String, count: Int)] {
        var counts: [String: Int] = [:]
        let locale = Locale(identifier: "th_TH") as CFLocale
        for root in roots {
            guard let walker = FileManager.default.enumerator(atPath: root) else { continue }
            for case let relative as String in walker {
                guard relative.hasSuffix(".strings") || relative.hasSuffix(".stringsdict"),
                      relative.contains("th.lproj/"),
                      let text = stringsFileText(root + "/" + relative), hasThai(text)
                else { continue }
                let cf = text as CFString
                let tokenizer = CFStringTokenizerCreate(
                    nil, cf, CFRangeMake(0, CFStringGetLength(cf)),
                    kCFStringTokenizerUnitWordBoundary, locale
                )
                let ns = text as NSString
                while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
                    let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
                    let token = ns.substring(with: NSRange(location: range.location, length: range.length))
                    if allThai(token), token.count >= 2 { counts[token, default: 0] += 1 }
                }
            }
        }
        return counts.sorted { $0.value > $1.value }.map { (word: $0.key, count: $0.value) }
    }

    // MARK: - The system Thai dictionary

    static func inflate(_ data: Data) -> Data? {
        let capacity = 16 * 1024 * 1024
        var buffer = [UInt8](repeating: 0, count: capacity)
        let written = data.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
            return compression_decode_buffer(&buffer, capacity, base, raw.count, nil, COMPRESSION_ZLIB)
        }
        guard written > 0 else { return nil }
        return Data(buffer[0..<written])
    }

    static func dictionaryBodies() -> [String] {
        let root = "/System/Library/AssetsV2/com_apple_MobileAsset_DictionaryServices_dictionary3macOS"
        guard let assets = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
        return assets
            .map { "\(root)/\($0)/AssetData/Thai.dictionary/Contents/Resources/Body.data" }
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    static func dictionaryHeadwords() -> Set<String> {
        var words: Set<String> = []
        guard let pattern = try? NSRegularExpression(pattern: "d:title=\"([^\"]+)\"") else { return words }
        for path in dictionaryBodies() {
            guard let data = FileManager.default.contents(atPath: path) else { continue }
            // The body is a run of zlib streams, each starting with 78 da.
            let bytes = [UInt8](data)
            var index = 0
            while index < bytes.count - 1 {
                guard bytes[index] == 0x78, bytes[index + 1] == 0xDA else { index += 1; continue }
                // Skip the 2-byte zlib header: Compression wants raw deflate.
                if let chunk = inflate(data.subdata(in: (index + 2)..<data.count)) {
                    // Entries are length-prefixed, so the stream is not valid
                    // UTF-8 end to end; decode lossily and pull the titles out.
                    let text = String(decoding: chunk, as: UTF8.self)
                    let ns = text as NSString
                    for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                        let title = ns.substring(with: match.range(at: 1))
                        if allThai(title), title.count >= 2 { words.insert(title) }
                    }
                }
                index += 2
            }
        }
        return words
    }
}
