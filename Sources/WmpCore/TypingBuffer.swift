import Foundation

/// The word being typed right now. Everything the corrector needs is here: the
/// keys pressed and the characters they actually produced, so the same run can
/// be re-rendered through the other layout without guessing.
public struct TypingBuffer {
    public private(set) var strokes: [Keystroke] = []
    /// One entry per key press. Kept separate from `typed` because a Thai vowel
    /// or tone mark merges into the previous grapheme cluster, so String's own
    /// `removeLast()` would drop two key presses at once.
    public private(set) var pieces: [String] = []

    public init() {}

    public var isEmpty: Bool { strokes.isEmpty }
    /// Key presses in this word.
    public var count: Int { strokes.count }
    public var typed: String { pieces.joined() }

    public mutating func append(keycode: UInt16, shift: Bool, character: String) {
        strokes.append(Keystroke(keycode: keycode, shift: shift))
        pieces.append(character)
    }

    public mutating func backspace() {
        guard !strokes.isEmpty else { return }
        strokes.removeLast()
        pieces.removeLast()
    }

    /// Re-label the same key presses after a mid-word layout switch: the strokes
    /// stand, but the characters on screen are now the other script's.
    public mutating func relabel(_ newPieces: [String]) {
        guard newPieces.count == strokes.count else { return }
        pieces = newPieces
    }

    public mutating func reset() {
        strokes.removeAll(keepingCapacity: true)
        pieces.removeAll(keepingCapacity: true)
    }

    /// Which script the characters actually landed in.
    public var script: Script? {
        if ThaiOrthography.containsThai(typed) { return .thai }
        if typed.contains(where: { $0.isLetter }) { return .latin }
        return nil
    }
}

public enum CharacterRole {
    case wordCharacter(String)
    case boundary
    case ignore
}

/// Only whitespace ends a word.
///
/// Punctuation cannot: nearly every symbol key on the Latin layout is a Thai
/// letter on the Thai one, so "ขอบคุณ" typed in English is "-v[86I". Treating
/// `-` or `[` as a boundary would shred exactly the words we are here to fix.
public func role(of character: String) -> CharacterRole {
    guard let first = character.unicodeScalars.first else { return .ignore }
    if first.value < 0x20 { return .boundary }          // return, tab, control keys
    if Character(first).isWhitespace { return .boundary }
    return .wordCharacter(character)
}
