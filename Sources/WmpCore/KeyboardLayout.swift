import Carbon
import Foundation

/// A single keyboard layout ("ABC", "Thai", ...) read straight out of the
/// system's 'uchr' data, so the tables are always the real ones rather than a
/// hand-copied chart.
public struct KeyboardLayout: Sendable {
    public let sourceID: String
    public let localizedName: String
    /// [keycode: (plain, shifted)]
    public let chars: [UInt16: (plain: String, shifted: String)]

    static let keycodeRange: [UInt16] = Array(0...53)

    public init?(source: TISInputSource) {
        func property(_ key: CFString) -> String? {
            guard let p = TISGetInputSourceProperty(source, key) else { return nil }
            return (Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String)
        }
        guard let id = property(kTISPropertyInputSourceID),
              let layoutPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }

        let data = Unmanaged<CFData>.fromOpaque(layoutPtr).takeUnretainedValue() as Data
        var table: [UInt16: (String, String)] = [:]
        for code in Self.keycodeRange {
            guard let plain = Self.translate(data, code, shift: false),
                  let shifted = Self.translate(data, code, shift: true),
                  !plain.isEmpty, !shifted.isEmpty
            else { continue }
            table[code] = (plain, shifted)
        }
        guard table.count > 20 else { return nil }

        self.sourceID = id
        self.localizedName = property(kTISPropertyLocalizedName) ?? id
        self.chars = table
    }

    private static func translate(_ data: Data, _ keycode: UInt16, shift: Bool) -> String? {
        var deadKeyState: UInt32 = 0
        var buffer = [UniChar](repeating: 0, count: 8)
        var length = 0
        let modifiers: UInt32 = shift ? UInt32(shiftKey >> 8) : 0
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return UCKeyTranslate(
                base.assumingMemoryBound(to: UCKeyboardLayout.self),
                keycode, UInt16(kUCKeyActionDown), modifiers, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, 8, &length, &buffer
            )
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: buffer, count: length)
    }

    public func character(keycode: UInt16, shift: Bool) -> String? {
        guard let entry = chars[keycode] else { return nil }
        return shift ? entry.shifted : entry.plain
    }

    /// [character: (keycode, shift)] - used to convert text we did not witness
    /// being typed (a selection, say).
    public var reverseMap: [String: (keycode: UInt16, shift: Bool)] {
        var map: [String: (UInt16, Bool)] = [:]
        for (code, entry) in chars {
            if map[entry.plain] == nil { map[entry.plain] = (code, false) }
            if map[entry.shifted] == nil { map[entry.shifted] = (code, true) }
        }
        return map
    }
}

/// The Latin/Thai layout pair currently installed, plus the input-source
/// switching that goes with a correction.
public final class LayoutPair {
    public let latin: KeyboardLayout
    public let thai: KeyboardLayout
    private let latinReverse: [String: (keycode: UInt16, shift: Bool)]
    private let thaiReverse: [String: (keycode: UInt16, shift: Bool)]

    public init?(latinPreference: [String] = ["com.apple.keylayout.ABC", "com.apple.keylayout.US"],
                 thaiPreference: [String] = ["com.apple.keylayout.Thai", "com.apple.keylayout.Thai-QWERTY", "com.apple.keylayout.Thai-PattaChote"]) {
        let installed = LayoutPair.installedLayouts()
        func pick(_ preference: [String]) -> KeyboardLayout? {
            for id in preference {
                if let hit = installed.first(where: { $0.sourceID == id }) { return hit }
            }
            return nil
        }
        guard let latin = pick(latinPreference), let thai = pick(thaiPreference) else { return nil }
        self.latin = latin
        self.thai = thai
        self.latinReverse = latin.reverseMap
        self.thaiReverse = thai.reverseMap
    }

    public static func installedLayouts() -> [KeyboardLayout] {
        let properties: [CFString: Any] = [kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource!]
        guard let list = TISCreateInputSourceList(properties as CFDictionary, false)?
            .takeRetainedValue() as? [TISInputSource] else { return [] }
        return list.compactMap(KeyboardLayout.init(source:))
    }

    /// Re-renders keystrokes through the other layout. This is exact: it uses
    /// the keys that were actually pressed, not a character round-trip.
    public func renderPieces(_ strokes: [Keystroke], as target: Script) -> [String] {
        let layout = target == .thai ? thai : latin
        return strokes.map { stroke in
            stroke.literal ?? layout.character(keycode: stroke.keycode, shift: stroke.shift) ?? ""
        }
    }

    public func render(_ strokes: [Keystroke], as target: Script) -> String {
        let layout = target == .thai ? thai : latin
        var out = ""
        for stroke in strokes {
            if let literal = stroke.literal {
                out += literal
            } else if let char = layout.character(keycode: stroke.keycode, shift: stroke.shift) {
                out += char
            }
        }
        return out
    }

    /// Character-level conversion that keeps whatever it cannot map.
    ///
    /// Used on a selection, where punctuation, numbers and stray characters are
    /// normal and refusing the whole thing over one of them would be useless.
    public func convertKeepingUnknown(text: String, to target: Script) -> String {
        let from = target == .thai ? latinReverse : thaiReverse
        let to = target == .thai ? thai : latin
        var out = ""
        for scalar in text.unicodeScalars {
            let key = String(scalar)
            if let (code, shift) = from[key], let mapped = to.character(keycode: code, shift: shift) {
                out += mapped
            } else {
                out += key
            }
        }
        return out
    }

    /// Character-level conversion for text we did not witness (manual mode).
    public func convert(text: String, to target: Script) -> String? {
        let from = target == .thai ? latinReverse : thaiReverse
        let to = target == .thai ? thai : latin
        var out = ""
        // Per scalar, not per Character: Thai vowel and tone marks combine into
        // the preceding grapheme cluster, but each one is its own key press.
        for scalar in text.unicodeScalars {
            let key = String(scalar)
            if let (code, shift) = from[key], let mapped = to.character(keycode: code, shift: shift) {
                out += mapped
            } else if key == " " || key == "\n" || key == "\t" {
                out += key
            } else {
                return nil
            }
        }
        return out
    }

    /// The keys someone would press to produce `text` on `script`. Used by the
    /// self-test to replay realistic wrong-layout typing.
    public func strokes(for text: String, on script: Script) -> [Keystroke]? {
        let reverse = script == .thai ? thaiReverse : latinReverse
        var out: [Keystroke] = []
        for scalar in text.unicodeScalars {
            guard let (code, shift) = reverse[String(scalar)] else { return nil }
            out.append(Keystroke(keycode: code, shift: shift))
        }
        return out
    }

    public func currentScript() -> Script? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let layout = KeyboardLayout(source: source) else { return nil }
        if layout.sourceID == thai.sourceID { return .thai }
        if layout.sourceID == latin.sourceID { return .latin }
        return nil
    }

    public func selectInputSource(_ script: Script) {
        let wanted = script == .thai ? thai.sourceID : latin.sourceID
        let properties: [CFString: Any] = [kTISPropertyInputSourceID: wanted]
        guard let list = TISCreateInputSourceList(properties as CFDictionary, false)?
            .takeRetainedValue() as? [TISInputSource], let source = list.first else { return }
        TISSelectInputSource(source)
    }
}

public enum Script: String, Sendable {
    case latin
    case thai
}

/// One key press, kept so a word can be re-rendered through the other layout.
public struct Keystroke: Sendable {
    public let keycode: UInt16
    public let shift: Bool
    /// Set for characters that came from somewhere other than a layout key
    /// (currently unused, reserved for pasted text).
    public let literal: String?

    public init(keycode: UInt16, shift: Bool, literal: String? = nil) {
        self.keycode = keycode
        self.shift = shift
        self.literal = literal
    }
}
