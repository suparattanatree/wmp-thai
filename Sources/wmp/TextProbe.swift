import ApplicationServices
import Foundation

/// Reads the text of whatever field has focus, through the Accessibility API we
/// already hold permission for.
///
/// This exists because "how much does one backspace delete" is not a fixed
/// answer: native Cocoa fields remove one Thai mark at a time, Electron and
/// Chromium fields remove a whole cluster. Counting key presses is guesswork;
/// looking at the text is not.
struct TextProbe {
    private let systemWide = AXUIElementCreateSystemWide()

    /// The selected text, when the app exposes it.
    func selectedText() -> String? {
        guard let field = focusedElement() else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(field, kAXSelectedTextAttribute as CFString, &value) == .success,
              let text = value as? String, !text.isEmpty
        else { return nil }
        return text
    }

    /// Replaces the selection in place. Many apps allow this; the ones that do
    /// not leave it to the caller to type over the selection instead.
    @discardableResult
    func replaceSelection(with text: String) -> Bool {
        guard let field = focusedElement() else { return false }
        return AXUIElementSetAttributeValue(field, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success
    }

    /// Same lookup, reachable from the context extension.
    func focusedElementForContext() -> AXUIElement? { focusedElement() }

    private func focusedElement() -> AXUIElement? {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID()
        else { return nil }
        return (element as! AXUIElement)
    }

    /// Nil when the app exposes nothing readable (terminals, secure fields,
    /// anything that opts out). Callers fall back to counting.
    func focusedText() -> String? {
        guard let field = focusedElement() else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(field, kAXValueAttribute as CFString, &value) == .success,
              let text = value as? String
        else { return nil }
        return text
    }
}
