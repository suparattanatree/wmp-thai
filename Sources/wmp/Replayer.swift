import AppKit
import Carbon
import CoreGraphics
import Foundation

/// Rewrites what was just typed: backspace over it, type the replacement.
///
/// Every event we post carries `magic` in its source-user-data field so the tap
/// can tell our own keystrokes from the user's and not chase its own tail.
final class Replayer {
    static let magic: Int64 = 0x4B45_5946_4958   // "KEYFIX"

    private let source = CGEventSource(stateID: .privateState)
    private let probe = TextProbe()
    private let deleteKeycode: CGKeyCode = 51
    /// Apps need a beat between synthetic events or they drop some.
    private let interEventDelay: useconds_t = 900

    private(set) var isReplaying = false

    func replace(_ original: String, with replacement: String, trailing: String) {
        isReplaying = true
        defer { isReplaying = false }

        // How much one backspace removes depends on the app: native Cocoa fields
        // delete a single Thai mark, Chromium and Electron delete the whole
        // cluster. So delete against the text itself rather than against a count,
        // and re-type anything an over-eager backspace took with it.
        let wanted = (original + trailing).unicodeScalars.count
        var restore = ""

        if let before = probe.focusedText() {
            let target = before.unicodeScalars.count - wanted
            var attempts = 0
            var current = before
            var blind = false
            while current.unicodeScalars.count > target, attempts < wanted + 4 {
                postKey(deleteKeycode)
                attempts += 1
                guard let now = waitForChange(from: current) else {
                    // The field stopped reporting changes. Rather than give up
                    // mid-way and leave half the word behind ("fe" in front of a
                    // corrected word), finish by count: one delete per remaining
                    // key press, which is what a plain text field does.
                    blind = true
                    break
                }
                current = now
            }
            if blind {
                let remaining = current.unicodeScalars.count - target
                for _ in 0..<max(0, remaining) { postKey(deleteKeycode) }
            } else {
                let overshoot = target - current.unicodeScalars.count
                if overshoot > 0 {
                    restore = String(String.UnicodeScalarView(before.unicodeScalars.dropLast(wanted).suffix(overshoot)))
                }
            }
        } else {
            // No readable field (terminals, secure input): fall back to counting
            // one delete per key press, which is what native fields do.
            for _ in 0..<wanted { postKey(deleteKeycode) }
        }

        type(restore + replacement + trailing)
    }

    /// The app handles our delete asynchronously, so poll briefly for the text to
    /// actually change. Nil means it never did: the field is not one we can read
    /// our way through, so stop rather than hammer it with more deletes.
    private func waitForChange(from previous: String) -> String? {
        for _ in 0..<24 {
            usleep(2500)
            guard let now = probe.focusedText() else { return nil }
            if now != previous { return now }
        }
        return nil
    }

    /// The text of the focused field, for callers that need to check what is on
    /// screen before touching it.
    func focusedText() -> String? { probe.focusedText() }

    func selectedText() -> String? { probe.selectedText() }

    @discardableResult
    func replaceSelection(with text: String) -> Bool { probe.replaceSelection(with: text) }

    /// Last resort for reading a selection: press ⌘C and look at the clipboard,
    /// then put the clipboard back the way it was. Apps that expose nothing to
    /// the Accessibility API still answer to this.
    func copySelection() -> String? {
        isReplaying = true
        defer { isReplaying = false }

        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        let before = pasteboard.changeCount

        postKey(8, flags: .maskCommand)          // ⌘C
        var copied: String?
        for _ in 0..<40 {
            usleep(5000)
            if pasteboard.changeCount != before {
                copied = pasteboard.string(forType: .string)
                break
            }
        }

        if let saved {
            pasteboard.clearContents()
            pasteboard.setString(saved, forType: .string)
        }
        return copied
    }

    func type(_ text: String) {
        // One event per scalar, the same shape as real typing.
        for scalar in text.unicodeScalars {
            postUnicode(String(scalar))
        }
    }

    private func postKey(_ keycode: CGKeyCode, flags: CGEventFlags = []) {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keycode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keycode, keyDown: false)
        else { return }
        down.flags = flags
        up.flags = flags
        stamp(down); stamp(up)
        down.post(tap: .cgSessionEventTap)
        usleep(interEventDelay)
        up.post(tap: .cgSessionEventTap)
        usleep(interEventDelay)
    }

    private func postUnicode(_ text: String) {
        var utf16 = Array(text.utf16)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else { return }
        // Only the key-down carries the text. Chromium and Electron insert on
        // both edges, so putting the string on the key-up as well types every
        // character twice: "ที่ใช้" came out as "ททีี่่ใใชช้้".
        down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        stamp(down); stamp(up)
        down.post(tap: .cgSessionEventTap)
        usleep(interEventDelay)
        up.post(tap: .cgSessionEventTap)
        usleep(interEventDelay)
    }

    private func stamp(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: Replayer.magic)
    }

    static func isOurs(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == magic
    }
}
