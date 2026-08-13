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
    /// Decided once per word: asking the Accessibility API what kind of field
    /// this is costs a cross-process call, and the answer cannot change while a
    /// word is being typed into it.
    private var skippingThisField = false

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
        // Our own events are stamped, so identity filters them. Keys typed
        // during a replay still belong in the buffer: they land on screen.
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

        if buffer.isEmpty { skippingThisField = shouldSkipCurrentField() }
        guard !skippingThisField else { return }

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

    /// Stay out of login boxes and excluded sites.
    private func shouldSkipCurrentField() -> Bool {
        guard settings.skipSensitiveFields || !settings.excludedHosts.isEmpty else { return false }
        let context = replayer.fieldContext()
        if settings.skipSensitiveFields, context.looksSensitive { return true }
        return settings.isExcluded(host: context.host)
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

    /// A pause sits between a finished word and mid-burst, so try both rules.
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
        case 37: convertSelection()
        default: break
        }
    }

    /// `fromMenu` hands focus back to the app being typed in first, or the undo
    /// lands on our own menu.
    func revertLastFix(fromMenu: Bool = false) {
        // A word fixed mid-way and typed on since: undo the whole word, not the
        // fragment that triggered it.
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
        // The fix may be old: reaching the menu takes a click and an app switch.
        // Check the text it produced is still where it was left.
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

    /// ⌃⌥L: flip the selection. Works on text this tool never saw being typed.
    func convertSelection(fromMenu: Bool = false) {
        if fromMenu, let bundleID = lastExternalBundleID,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            app.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.convertSelection()
            }
            return
        }

        // The Accessibility API first, the clipboard only if the app hides its
        // selection from it.
        let selection = replayer.selectedText() ?? replayer.copySelection()
        guard let selection, !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            convertLastWord()
            return
        }

        let target: Script = ThaiOrthography.containsThai(selection) ? .latin : .thai
        let converted = corrector.convertSelection(selection, layouts: layouts)
        guard converted != selection else { return }

        buffer.reset()
        lastFix = nil
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Setting the selection outright is cleaner where it works; typing
            // over it is what every other app understands.
            if !self.replayer.replaceSelection(with: converted) {
                self.replayer.type(converted)
            }
            if self.settings.switchInputSource {
                self.layouts.selectInputSource(target)
            }
            self.onCorrection?(Correction(original: selection, replacement: converted,
                                          targetScript: target, originalScore: 0, replacementScore: 1),
                               false)
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
