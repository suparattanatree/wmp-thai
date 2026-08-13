import ApplicationServices
import Foundation

/// Reads the focused field through the Accessibility API. Needed because one
/// backspace deletes a mark in Cocoa and a whole cluster in Chromium.
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

    /// Replaces the selection in place where the app allows it.
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
