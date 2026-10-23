import AppKit
import SwiftUI

/// Single-line text field that tints given character ranges (detected dates) while you type.
/// SwiftUI's TextField can't style ranges, so this wraps NSTextField and paints the ranges as rendering
/// attributes on its field editor (the text itself is never changed).
struct HighlightField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var font: NSFont
    var highlights: [NSRange]
    var focusOnAppear = false
    var onSubmit: () -> Void = {}
    var onEscape: () -> Void = {}
    var onEndEditing: () -> Void = {}

    static let tint = NSColor.controlAccentColor.withAlphaComponent(0.28)

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField()
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.font = font
        f.placeholderString = placeholder
        f.lineBreakMode = .byTruncatingTail
        f.cell?.usesSingleLineMode = true
        f.cell?.isScrollable = true
        f.delegate = context.coordinator
        f.stringValue = text
        f.setContentHuggingPriority(.defaultLow, for: .horizontal)
        f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if focusOnAppear {
            DispatchQueue.main.async {
                f.window?.makeFirstResponder(f)
                (f.currentEditor() as? NSTextView)?.moveToEndOfDocument(nil)
            }
        }
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        context.coordinator.parent = self
        if f.stringValue != text { f.stringValue = text }
        f.font = font
        paint(f)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    private func paint(_ f: NSTextField) {
        let length = (f.stringValue as NSString).length
        let ranges = highlights.filter { NSMaxRange($0) <= length }
        guard let editor = f.currentEditor() as? NSTextView else {
            // Not editing: show the tint on the static string.
            let s = NSMutableAttributedString(string: f.stringValue, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
            for r in ranges { s.addAttribute(.backgroundColor, value: Self.tint, range: r) }
            f.attributedStringValue = s
            return
        }
        if let tlm = editor.textLayoutManager, let content = tlm.textContentManager {
            tlm.removeRenderingAttribute(.backgroundColor, for: tlm.documentRange)
            for r in ranges {
                guard let start = content.location(content.documentRange.location, offsetBy: r.location),
                      let end = content.location(start, offsetBy: r.length),
                      let range = NSTextRange(location: start, end: end) else { continue }
                tlm.addRenderingAttribute(.backgroundColor, value: Self.tint, for: range)
            }
        } else if let lm = editor.layoutManager {
            lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: length))
            for r in ranges { lm.addTemporaryAttribute(.backgroundColor, value: Self.tint, forCharacterRange: r) }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: HighlightField
        init(_ parent: HighlightField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let f = note.object as? NSTextField else { return }
            parent.text = f.stringValue
        }

        func controlTextDidEndEditing(_ note: Notification) { parent.onEndEditing() }

        func controlTextDidBeginEditing(_ note: Notification) {
            guard let f = note.object as? NSTextField else { return }
            DispatchQueue.main.async { self.parent.paint(f) }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit(); return true
            case #selector(NSResponder.cancelOperation(_:)): parent.onEscape(); return true
            default: return false
            }
        }
    }
}
