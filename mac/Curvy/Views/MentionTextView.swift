import AppKit
import SwiftUI

/// `NSTextView` wrapped for SwiftUI use in the chat composer. Replaces
/// the previous `TextField(axis: .vertical)` because @-mention detection
/// needs three things SwiftUI's `TextField` doesn't expose: real caret
/// position, real key-event interception (to forward arrow keys to a
/// SwiftUI picker without losing them to text-field navigation), and
/// the ability to mutate selection ranges from outside the view (for
/// committing a picked mention back into the buffer).
///
/// Behaviour preserved from the prior `TextField` implementation:
/// - `Return` submits (calls `onSend`).
/// - `Shift+Return` inserts a literal `\n` (not `U+2028`, which is
///   `insertLineBreak:`'s default — JSON in the wire format must stay
///   well-formed).
/// - Vertical autosize: 1 to `maxLines`, scrolling beyond.
/// - Two-way text binding, plain styling that matches the rest of
///   the chrome (clear background, system 14pt, label foreground).
///
/// New behaviour:
/// - When a `@<word>` token is present at the caret, `activeQuery` is
///   set to the word after `@`. Setting it to `nil` means no picker.
/// - When `activeQuery` is non-nil, ↑/↓/Tab/Enter/Esc are forwarded as
///   `onPickerNavigate` / `onPickerCommit` / `onPickerDismiss` callbacks
///   so the parent's SwiftUI picker can handle them. Without this
///   interception the text view would consume arrow keys for caret
///   movement and the picker would be unreachable from the keyboard.
/// - The parent calls `controller.commit(name:)` to insert
///   `@<name> ` at the caret (replacing the `@<query>` token in
///   place). Done inside the wrapper because only the live `NSTextView`
///   knows the authoritative selection range at commit time.
@MainActor
struct MentionTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    @Binding var activeQuery: String?
    let pickerActive: Bool
    let placeholder: String
    let font: NSFont
    let maxLines: Int
    let controller: MentionTextController
    let onSend: () -> Void
    let onPickerNavigate: (Int) -> Void
    let onPickerCommit: () -> Void
    let onPickerDismiss: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let textView = MentionNSTextView()
        textView.delegate = context.coordinator
        textView.font = font
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.string = text
        textView.placeholder = placeholder

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.installCommitHandler()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? MentionNSTextView else { return }
        context.coordinator.parent = self
        context.coordinator.installCommitHandler()

        if textView.string != text {
            // External binding update (e.g. parent cleared the field
            // post-send). Preserve caret position when feasible.
            let prev = textView.selectedRange()
            textView.string = text
            let newLen = (text as NSString).length
            let clamped = NSRange(
                location: min(prev.location, newLen),
                length: 0
            )
            textView.setSelectedRange(clamped)
        }

        if textView.placeholder != placeholder {
            textView.placeholder = placeholder
            textView.needsDisplay = true
        }

        // First time the view sits inside a window, take focus so
        // the user can start typing immediately on app launch —
        // matches the previous TextField + @FocusState behavior.
        if !context.coordinator.didFocusOnce, let window = scrollView.window {
            window.makeFirstResponder(textView)
            context.coordinator.didFocusOnce = true
        }

        // Autosize. Force layout so `usedRect` reflects the freshest
        // text, then clamp into [1 line, maxLines]. Padding mirrors
        // `textContainerInset.height` * 2.
        if let lm = textView.layoutManager, let tc = textView.textContainer {
            lm.ensureLayout(for: tc)
            let used = lm.usedRect(for: tc).height
            let line = font.boundingRectForFont.height
            let chrome: CGFloat = 8 // textContainerInset top + bottom
            let minH = line + chrome
            let maxH = line * CGFloat(maxLines) + chrome
            let needed = max(minH, min(used + chrome, maxH))
            if abs(needed - height) > 0.5 {
                DispatchQueue.main.async { self.height = needed }
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MentionTextView
        weak var textView: MentionNSTextView?
        /// One-shot guard for "focus the composer when the window
        /// first attaches the view." `makeNSView` runs before the
        /// view is in a window so we can't makeFirstResponder there;
        /// `updateNSView` runs again once the hierarchy is wired,
        /// which is when this fires. Subsequent updates are no-ops
        /// so we don't fight the user's own focus changes.
        var didFocusOnce: Bool = false

        init(_ parent: MentionTextView) {
            self.parent = parent
        }

        /// Wire the parent's `controller.commit(name:)` to a closure
        /// that mutates the live NSTextView. Done in `makeNSView` and
        /// re-done in `updateNSView` because the SwiftUI struct is
        /// transient — `parent` and `controller` get rebuilt on each
        /// render, but `textView` and `Coordinator` persist.
        func installCommitHandler() {
            parent.controller.commitMention = { [weak self] name in
                self?.commit(mention: name)
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? MentionNSTextView else { return }
            // Push text back to SwiftUI binding before re-evaluating
            // the mention query, so a subsequent `updateNSView` finds
            // the strings already in sync.
            parent.text = tv.string
            updateMentionQuery(in: tv)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? MentionNSTextView else { return }
            updateMentionQuery(in: tv)
        }

        private func updateMentionQuery(in tv: NSTextView) {
            let body = tv.string
            let caret = tv.selectedRange().location
            let q = MentionQueryScanner.scan(body: body, caretUTF16: caret)
            if q != parent.activeQuery {
                parent.activeQuery = q
            }
        }

        // MARK: - Key-event interception

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // Picker active: arrow keys navigate, Enter/Tab commit,
            // Esc dismisses. Without this interception arrow keys
            // would move the text caret instead of moving picker
            // selection.
            if parent.pickerActive {
                switch commandSelector {
                case #selector(NSResponder.moveUp(_:)):
                    parent.onPickerNavigate(-1)
                    return true
                case #selector(NSResponder.moveDown(_:)):
                    parent.onPickerNavigate(+1)
                    return true
                case #selector(NSResponder.insertTab(_:)),
                     #selector(NSResponder.insertNewline(_:)):
                    parent.onPickerCommit()
                    return true
                case #selector(NSResponder.cancelOperation(_:)):
                    parent.onPickerDismiss()
                    return true
                default:
                    break
                }
            }

            // Default Return → send. Shift+Return goes through
            // `insertLineBreak:`, which we route to a literal `\n` so
            // the wire format stays well-formed JSON (the system
            // default is U+2028, which round-trips fine but reads
            // poorly in any debug log of the inner JSON).
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSend()
                return true
            }
            if commandSelector == #selector(NSResponder.insertLineBreak(_:)) {
                textView.insertText("\n", replacementRange: textView.selectedRange())
                return true
            }
            return false
        }

        // MARK: - Mention commit

        /// Replace the `@<query>` token directly preceding the caret
        /// with `@<name> ` (trailing space). Mutates the live text
        /// view, then pushes the new string back through the SwiftUI
        /// binding and clears the active query so the picker dismisses.
        private func commit(mention name: String) {
            guard let tv = textView else { return }
            let body = tv.string
            let caret = tv.selectedRange().location
            guard let tokenRange = MentionQueryScanner.tokenRange(
                body: body,
                caretUTF16: caret
            ) else {
                // No active token under caret — the picker shouldn't
                // have committed. Bail rather than silently inserting
                // somewhere arbitrary.
                return
            }
            let replacement = "@\(name) "
            tv.shouldChangeText(in: tokenRange, replacementString: replacement)
            tv.replaceCharacters(in: tokenRange, with: replacement)
            tv.didChangeText()
            parent.text = tv.string
            parent.activeQuery = nil
        }
    }
}

/// Stateless helpers for finding the active `@<query>` token relative
/// to the caret. Pulled out of the coordinator so they can be unit-
/// tested without standing up an NSTextView.
enum MentionQueryScanner {
    /// Returns the substring after `@` and before the caret if the
    /// caret is inside a valid `@<word>` token; otherwise `nil`.
    /// "Valid" means the `@` is at start of body or preceded by
    /// whitespace, and there's no whitespace between the `@` and the
    /// caret.
    static func scan(body: String, caretUTF16 caret: Int) -> String? {
        let ns = body as NSString
        guard caret <= ns.length else { return nil }
        var i = caret
        while i > 0 {
            let unit = ns.character(at: i - 1)
            if unit == 0x40 { // '@'
                let validStart: Bool
                if i - 1 == 0 {
                    validStart = true
                } else {
                    validStart = isWhitespace(ns.character(at: i - 2))
                }
                guard validStart else { return nil }
                return ns.substring(with: NSRange(location: i, length: caret - i))
            }
            if isWhitespace(unit) { return nil }
            i -= 1
        }
        return nil
    }

    /// Returns the NSRange covering the active `@<query>` token
    /// (including the `@`), or `nil` if there isn't one.
    static func tokenRange(body: String, caretUTF16 caret: Int) -> NSRange? {
        let ns = body as NSString
        guard caret <= ns.length else { return nil }
        var i = caret
        while i > 0 {
            let unit = ns.character(at: i - 1)
            if unit == 0x40 {
                let validStart: Bool
                if i - 1 == 0 {
                    validStart = true
                } else {
                    validStart = isWhitespace(ns.character(at: i - 2))
                }
                guard validStart else { return nil }
                return NSRange(location: i - 1, length: caret - (i - 1))
            }
            if isWhitespace(unit) { return nil }
            i -= 1
        }
        return nil
    }

    private static func isWhitespace(_ u: unichar) -> Bool {
        // ASCII space, tab, newline, carriage return — sufficient
        // for boundary detection in display-name @-mentions.
        u == 0x20 || u == 0x09 || u == 0x0A || u == 0x0D
    }
}

/// Lightweight pointer the parent uses to ask the wrapper to commit a
/// picked mention. Decouples "the SwiftUI picker selected a name" from
/// "the NSTextView mutates its buffer" — the parent doesn't need
/// access to the text view, just to the controller.
@MainActor
final class MentionTextController {
    fileprivate var commitMention: ((String) -> Void)?

    func commit(_ name: String) {
        commitMention?(name)
    }
}

/// `NSTextView` subclass that paints a placeholder when empty. AppKit
/// doesn't ship a placeholder primitive on `NSTextView` (only on
/// `NSTextField` / `NSSearchField`), so we draw it manually. Cheap —
/// a single string draw when there's no content.
final class MentionNSTextView: NSTextView {
    var placeholder: String = "" {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let font = self.font ?? NSFont.systemFont(ofSize: 14)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.6)
        ]
        let attributed = NSAttributedString(string: placeholder, attributes: attrs)
        let inset = textContainerInset
        let origin = NSPoint(x: inset.width + 5, y: inset.height)
        attributed.draw(at: origin)
    }
}

