// corpusgen: builds the Thai word list this machine's wmp uses.
//
// Two local sources, both already on the Mac:
//   1. macOS's own Thai dictionary (headwords only)
//   2. every Thai UI string macOS ships (th.lproj *.strings), segmented with
//      the ICU Thai word breaker
//
// It reads only local system resources and writes a plain word list, so nothing
// is redistributed - run it on the machine that will run wmp.
//
//   swift run corpusgen Sources/WmpCore/Resources/th_words.txt

import Compression
import Foundation

let outPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Sources/WmpCore/Resources/th_words.txt"

let roots = ["/System/Library", "/System/Applications", "/Applications"]
let minCount = 3

func isThaiScalar(_ u: Unicode.Scalar) -> Bool { (0x0E00...0x0E7F).contains(Int(u.value)) }
func hasThai(_ s: String) -> Bool { s.unicodeScalars.contains(where: isThaiScalar) }
func allThai(_ s: String) -> Bool { !s.isEmpty && s.unicodeScalars.allSatisfy(isThaiScalar) }

func stringsFileText(_ path: String) -> String? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    if data.starts(with: Array("bplist".utf8)) {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return nil }
        var parts: [String] = []
        func walk(_ any: Any) {
            switch any {
            case let d as [String: Any]: d.values.forEach(walk)
            case let a as [Any]: a.forEach(walk)
            case let s as String: parts.append(s)
            default: break
            }
        }
        walk(plist)
        return parts.joined(separator: "\n")
    }
    if let utf16 = String(data: data, encoding: .utf16), hasThai(utf16) { return utf16 }
    return String(data: data, encoding: .utf8)
}

func tokens(_ text: String) -> [String] {
    let cf = text as CFString
    let tokenizer = CFStringTokenizerCreate(
        nil, cf, CFRangeMake(0, CFStringGetLength(cf)),
        kCFStringTokenizerUnitWordBoundary, Locale(identifier: "th_TH") as CFLocale
    )
    var out: [String] = []
    let ns = text as NSString
    while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
        let r = CFStringTokenizerGetCurrentTokenRange(tokenizer)
        out.append(ns.substring(with: NSRange(location: r.location, length: r.length)))
    }
    return out
}

// MARK: - macOS Thai dictionary headwords

func inflate(_ data: Data) -> Data? {
    let capacity = 16 * 1024 * 1024
    var out = Data()
    var buffer = [UInt8](repeating: 0, count: capacity)
    let written = data.withUnsafeBytes { raw -> Int in
        guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
        return compression_decode_buffer(&buffer, capacity, base, raw.count, nil, COMPRESSION_ZLIB)
    }
    guard written > 0 else { return nil }
    out.append(contentsOf: buffer[0..<written])
    return out
}

func dictionaryBodies() -> [String] {
    let root = "/System/Library/AssetsV2/com_apple_MobileAsset_DictionaryServices_dictionary3macOS"
    guard let assets = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
    return assets
        .map { "\(root)/\($0)/AssetData/Thai.dictionary/Contents/Resources/Body.data" }
        .filter { FileManager.default.fileExists(atPath: $0) }
}

func headwords() -> Set<String> {
    var words: Set<String> = []
    let pattern = try! NSRegularExpression(pattern: "d:title=\"([^\"]+)\"")
    for path in dictionaryBodies() {
        guard let data = FileManager.default.contents(atPath: path) else { continue }
        // Apple stores the body as a run of zlib streams; each starts with 78 da.
        var index = 0
        let bytes = [UInt8](data)
        while index < bytes.count - 1 {
            guard bytes[index] == 0x78, bytes[index + 1] == 0xDA else { index += 1; continue }
            // Skip the 2-byte zlib header: Compression wants a raw deflate stream.
            if let chunk = inflate(data.subdata(in: (index + 2)..<data.count)) {
                // Entries are length-prefixed, so the stream is not valid UTF-8
                // end to end; decode lossily and pull the titles out.
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

let dictWords = headwords()
FileHandle.standardError.write("macOS Thai dictionary: \(dictWords.count) headwords\n".data(using: .utf8)!)

// MARK: - Thai UI strings

var counts: [String: Int] = [:]
var fileCount = 0

for root in roots {
    guard let walker = FileManager.default.enumerator(atPath: root) else { continue }
    for case let rel as String in walker {
        guard rel.hasSuffix(".strings") || rel.hasSuffix(".stringsdict") else { continue }
        guard rel.contains("th.lproj/") else { continue }
        guard let text = stringsFileText(root + "/" + rel), hasThai(text) else { continue }
        fileCount += 1
        for token in tokens(text) where allThai(token) && token.count >= 2 {
            counts[token, default: 0] += 1
        }
    }
    FileHandle.standardError.write("scanned \(root), \(fileCount) files, \(counts.count) words\n".data(using: .utf8)!)
}

// MARK: - Common English
//
// /usr/share/dict/words holds 235k entries including "miim" and "meso", so it
// cannot tell a real word from an accident. Words that appear in the system's
// own English UI are the ones people actually type.

func commonEnglish() -> Set<String> {
    var counts: [String: Int] = [:]
    for root in roots {
        guard let walker = FileManager.default.enumerator(atPath: root) else { continue }
        for case let rel as String in walker {
            guard rel.hasSuffix(".strings") || rel.hasSuffix(".stringsdict") else { continue }
            guard rel.contains("en.lproj/") || rel.contains("English.lproj/") else { continue }
            guard let text = stringsFileText(root + "/" + rel) else { continue }
            for token in text.split(whereSeparator: { !$0.isLetter && $0 != "'" }) {
                let word = token.lowercased()
                guard word.count >= 2, word.allSatisfy({ $0.isASCII && $0.isLetter }) else { continue }
                counts[word, default: 0] += 1
            }
        }
    }
    return Set(counts.filter { $0.value >= 3 }.keys)
}

let englishWords = commonEnglish()
FileHandle.standardError.write("common English: \(englishWords.count) words\n".data(using: .utf8)!)
let englishPath = (outPath as NSString).deletingLastPathComponent + "/en_words.txt"
try englishWords.sorted().joined(separator: "\n").write(toFile: englishPath, atomically: true, encoding: .utf8)

let corpusWords = Set(counts.filter { $0.value >= minCount }.keys)
FileHandle.standardError.write("UI strings: \(corpusWords.count) words\n".data(using: .utf8)!)

let kept = dictWords.union(corpusWords).sorted()
try kept.joined(separator: "\n").write(toFile: outPath, atomically: true, encoding: .utf8)
FileHandle.standardError.write("wrote \(kept.count) words to \(outPath)\n".data(using: .utf8)!)
