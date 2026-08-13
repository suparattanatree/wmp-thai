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

    /// Nil when the app exposes nothing readable (terminals, secure fields,
    /// anything that opts out). Callers fall back to counting.
    func focusedText() -> String? {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID()
        else { return nil }

        let field = element as! AXUIElement
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(field, kAXValueAttribute as CFString, &value) == .success,
              let text = value as? String
        else { return nil }
        return text
    }
}
