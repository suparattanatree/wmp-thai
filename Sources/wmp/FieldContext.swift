import ApplicationServices
import Foundation

/// What kind of field has focus, and on what page.
///
/// Used to stay out of places typing corrections do not belong: password boxes,
/// login forms, and any site the user has excluded. Read once per word rather
/// than per keystroke, because each of these is a cross-process call.
struct FieldContext {
    var subrole: String?
    /// Whatever the app calls this field: title, placeholder or description.
    var labels: [String]
    /// The page the focused window is showing, when it is a browser.
    var url: URL?

    var isSecure: Bool { subrole == (kAXSecureTextFieldSubrole as String) }

    /// Fields that ask for credentials. Matching on what the field calls itself
    /// is a heuristic, but it is the only signal a web page reliably exposes.
    var looksSensitive: Bool {
        if isSecure { return true }
        let needles = ["password", "passcode", "username", "user name", "user id", "email", "e-mail",
                       "รหัสผ่าน", "รหัส", "ชื่อผู้ใช้", "อีเมล", "บัญชี"]
        return labels.contains { label in
            let lower = label.lowercased()
            return needles.contains { lower.contains($0) }
        }
    }

    var host: String? {
        guard let host = url?.host else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

extension TextProbe {
    func fieldContext() -> FieldContext {
        var context = FieldContext(subrole: nil, labels: [], url: nil)
        guard let field = focusedElementForContext() else { return context }

        func string(_ attribute: String, of element: AXUIElement) -> String? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
            if let text = value as? String { return text }
            if let url = value as? URL { return url.absoluteString }
            return nil
        }

        context.subrole = string(kAXSubroleAttribute as String, of: field)
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute,
                          kAXHelpAttribute, kAXRoleDescriptionAttribute] as [String] {
            if let text = string(attribute, of: field), !text.isEmpty { context.labels.append(text) }
        }

        // The page URL lives on the window, not the field: browsers publish it as
        // AXDocument on the window holding the web area.
        var element: AXUIElement? = field
        for _ in 0..<8 {
            guard let current = element else { break }
            if let document = string(kAXDocumentAttribute as String, of: current),
               let url = URL(string: document) {
                context.url = url
                break
            }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parent) == .success,
                  let next = parent, CFGetTypeID(next) == AXUIElementGetTypeID()
            else { break }
            element = (next as! AXUIElement)
        }
        return context
    }
}
