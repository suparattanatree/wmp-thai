import AppKit
import Carbon
import CoreGraphics
import Foundation
import WmpCore

/// Watches typing, decides, and rewrites. One instance, driven by the event tap.
final class Engine {
    private let layouts: LayoutPair
    private let corrector: Corrector
    private let replayer = Replayer()
    private let settings: Settings

    private var buffer = TypingBuffer()
    /// The word just finished, kept so the manual hotkey can still reach it.
    private var lastWord: (buffer: TypingBuffer, trailing: String)?
    /// Kept with the app it happened in, so an undo can tell whether it is still
    /// looking at the same text.
    private var lastFix: (correction: Correction, trailing: String, bundleID: String?)?
    /// Cached instead of asked per keystroke: NSWorkspace lookups are not free
    /// and the answer only changes when the front app does.
    private var frontmostBundleID: String?
    /// The last app that was not this one. Undo needs it: opening our own menu
    /// makes us frontmost, and the text to fix lives in whatever was in front
    /// before that.
    private var lastExternalBundleID: String?
    /// One mid-word switch per word: after that, trust what is being typed.
    private var switchedThisWord = false
    /// Fires when typing pauses: the third moment a fix can happen, next to
    /// mid-word and the space bar.
    private var idleTimer: Timer?

    var onCorrection: ((Correction, _ midWord: Bool) -> Void)?

    init(layouts: LayoutPair, corrector: Corrector, settings: Settings) {
        self.layouts = layouts
        self.corrector = corrector
        self.settings = settings
        frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        lastExternalBundleID = frontmostBundleID
    }

    // MARK: - Event entry points

    func handleKeyDown(_ event: CGEvent) {
        // Our own synthetic events are stamped, so they are filtered by identity
        // rather than by a busy flag. Keys the user types while a fix is being
        // replayed still belong in the buffer: they land on screen either way,
        // and dropping them would leave the buffer out of step with the text.
        guard settings.enabled, !Replayer.isOurs(event) else { return }
        // Never look at anything typed into a password field.
        guard !IsSecureEventInputEnabled() else { buffer.reset(); return }
        guard !settings.isExcluded(frontmostBundleID) else { return }

        let keycode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let shift = flags.contains(.maskShift)

        if flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate) {
            handleHotkey(keycode: keycode, flags: flags)
            buffer.reset()
            return
        }

        switch keycode {
        case 51:                      // delete
            buffer.backspace()
            scheduleIdleFix()
            return
        case 123...126, 115, 116, 119, 121, 53:   // arrows, home/end/page, esc
            cancelIdleFix()
            buffer.reset()
            return
        default:
            break
        }

        let character = unicodeString(from: event)
        switch role(of: character) {
        case .wordCharacter(let text):
            buffer.append(keycode: keycode, shift: shift, character: text)
            considerLiveSwitch()
            scheduleIdleFix()
        case .boundary:
            finishWord(trailing: character)
        case .ignore:
            break
        }
    }

    func handleMouseDown() {
        cancelIdleFix()
        buffer.reset()
        switchedThisWord = false
        lastWord = nil
        // lastFix deliberately survives: reaching the menu item that undoes it
        // takes a click and an app switch, and clearing it here made that item
        // impossible to use. revertLastFix checks the text is still there.
    }

    func handleAppSwitch() {
        frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if frontmostBundleID != Bundle.main.bundleIdentifier {
            lastExternalBundleID = frontmostBundleID
        }
        cancelIdleFix()
        buffer.reset()
        switchedThisWord = false
        lastWord = nil
    }

    // MARK: - Decisions

    /// Called on every keystroke: switch the keyboard mid-word once it is clear
    /// the word is landing in the wrong script, so the rest of it types cleanly.
    /// Restart the pause countdown on every keystroke: the fix lands only once
    /// the user actually stops.
    private func scheduleIdleFix() {
        idleTimer?.invalidate()
        idleTimer = nil
        guard settings.idleFix, settings.autoFix, !switchedThisWord, !buffer.isEmpty else { return }
        let delay = max(100, settings.idleDelayMilliseconds)
        idleTimer = Timer.scheduledTimer(withTimeInterval: Double(delay) / 1000, repeats: false) { [weak self] _ in
            self?.fixOnPause()
        }
    }

    private func cancelIdleFix() {
        idleTimer?.invalidate()
        idleTimer = nil
    }

    /// A pause is weaker evidence than a finished word but stronger than the
    /// middle of a burst, so try both rule sets: the full-word one first, then
    /// the stricter mid-word one for words that are not finished yet.
    private func fixOnPause() {
        guard settings.enabled, settings.autoFix, !switchedThisWord, !buffer.isEmpty else { return }
        guard let correction = corrector.evaluate(buffer) ?? corrector.evaluatePrefix(buffer) else { return }
        switchedThisWord = true
        buffer.relabel(layouts.renderPieces(buffer.strokes, as: correction.targetScript))
        apply(correction, trailing: "", midWord: true)
    }

    private func considerLiveSwitch() {
        guard settings.liveSwitch, settings.autoFix, !switchedThisWord else { return }
        guard let correction = corrector.evaluatePrefix(buffer) else { return }
        switchedThisWord = true
        buffer.relabel(layouts.renderPieces(buffer.strokes, as: correction.targetScript))
        apply(correction, trailing: "", midWord: true)
    }

    private func finishWord(trailing: String) {
        cancelIdleFix()
        defer {
            lastWord = (buffer, trailing)
            buffer.reset()
            switchedThisWord = false
        }
        guard let correction = corrector.evaluate(buffer) else { return }
        guard settings.autoFix else { onCorrection?(correction, false); return }
        apply(correction, trailing: trailing)
    }

    func configure(thresholds: CorrectorThresholds, allowedTargets: Set<Script>, guessWhenUnreadable: Bool) {
        corrector.thresholds = thresholds
        corrector.allowedTargets = allowedTargets
        corrector.guessWhenUnreadable = guessWhenUnreadable
    }

    private func apply(_ correction: Correction, trailing: String, midWord: Bool = false) {
        let snapshot = correction
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.replayer.replace(snapshot.original, with: snapshot.replacement, trailing: trailing)
            if self.settings.switchInputSource {
                self.layouts.selectInputSource(snapshot.targetScript)
            }
            self.lastFix = (snapshot, trailing, self.lastExternalBundleID)
            self.onCorrection?(snapshot, midWord)
        }
    }

    // MARK: - Hotkeys

    /// Undoing says the original was a real word we did not know. Remember it,
    /// so the same "correction" does not come back tomorrow.
    private func learn(_ word: String) {
        WordListBuilder.addUserWord(word)
        NotificationCenter.default.post(name: .wmpWordListsRebuilt, object: nil)
    }

    /// ⌃⌥Z reverts the last automatic fix, ⌃⌥L converts the last word by hand.
    private func handleHotkey(keycode: UInt16, flags: CGEventFlags) {
        let wanted: CGEventFlags = [.maskControl, .maskAlternate]
        guard flags.contains(wanted), !flags.contains(.maskCommand) else { return }
        switch keycode {
        case 6: revertLastFix()
        case 37: convertLastWord()
        default: break
        }
    }

    /// `fromMenu` means our own menu is what triggered this: focus has to go back
    /// to the app being typed in before any keystroke is posted, or the undo
    /// lands on our menu instead of the text.
    func revertLastFix(fromMenu: Bool = false) {
        // A word that was fixed mid-way and typed on since: undo the whole word,
        // not just the fragment that triggered the fix. The buffer holds the key
        // presses, so rendering them in the other script gives what the user
        // meant to see.
        if switchedThisWord, !buffer.isEmpty, let script = buffer.script {
            let back: Script = script == .thai ? .latin : .thai
            let original = layouts.render(buffer.strokes, as: back)
            let current = buffer.typed
            guard !original.isEmpty else { return }
            learn(current)
            buffer.relabel(layouts.renderPieces(buffer.strokes, as: back))
            lastFix = nil
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.replayer.replace(current, with: original, trailing: "")
                if self.settings.switchInputSource { self.layouts.selectInputSource(back) }
            }
            return
        }

        guard let fix = lastFix else { return }
        if fromMenu {
            if let bundleID = fix.bundleID,
               let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                app.activate()
            }
            // Give the app a moment to take focus back before typing into it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.performRevert(fix)
            }
            lastFix = nil
            return
        }
        // The fix may be old by now: the menu bar itself takes a click and an app
        // switch to reach. Rather than forgetting the fix on every click, check
        // that the text it produced is still sitting where it was left.
        let typed = fix.correction.replacement + fix.trailing
        if let onScreen = replayer.focusedText() {
            guard onScreen.hasSuffix(typed) else { return }
        } else {
            guard fix.bundleID == lastExternalBundleID else { return }
        }

        lastFix = nil
        performRevert(fix)
    }

    private func performRevert(_ fix: (correction: Correction, trailing: String, bundleID: String?)) {
        learn(fix.correction.original)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.replayer.replace(fix.correction.replacement, with: fix.correction.original, trailing: fix.trailing)
            if self.settings.switchInputSource {
                let back: Script = fix.correction.targetScript == .thai ? .latin : .thai
                self.layouts.selectInputSource(back)
            }
        }
    }

    func convertLastWord() {
        let target: (buffer: TypingBuffer, trailing: String)?
        if !buffer.isEmpty {
            target = (buffer, "")
        } else {
            target = lastWord
        }
        guard let target, !target.buffer.isEmpty, let script = target.buffer.script else { return }
        let other: Script = script == .thai ? .latin : .thai
        let replacement = layouts.render(target.buffer.strokes, as: other)
        guard !replacement.isEmpty else { return }
        let correction = Correction(original: target.buffer.typed, replacement: replacement,
                                    targetScript: other, originalScore: 0, replacementScore: 1)
        buffer.reset()
        lastWord = nil
        apply(correction, trailing: target.trailing)
    }

    // MARK: - Helpers

    private func unicodeString(from event: CGEvent) -> String {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length, unicodeString: &buffer)
        guard length > 0 else { return "" }
        return String(utf16CodeUnits: buffer, count: length)
    }
}
