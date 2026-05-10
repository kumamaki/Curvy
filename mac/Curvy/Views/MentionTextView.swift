import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
    /// Called when ⌘V hits the text view with image data on the
    /// pasteboard. Routed up to `ChatView.handleProviders` so the
    /// existing GIF/NSImage/file-URL pipeline handles it. When the
    /// pasteboard has no image, the override falls through to
    /// `super.paste(_:)` and this is never invoked.
    let onPasteImage: ([NSItemProvider]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            activeQuery: $activeQuery,
            pickerActive: pickerActive,
            onSend: onSend,
            onPickerNavigate: onPickerNavigate,
            onPickerCommit: onPickerCommit,
            onPickerDismiss: onPickerDismiss
        )
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

        textView.onPasteImage = onPasteImage
        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.installCommitHandler(controller: controller)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? MentionNSTextView else { return }
        // Re-assign on every render so the closure captures the freshest
        // SwiftUI state. The struct is rebuilt each render; the closure
        // it carries is too. Without this re-assignment the text view
        // would keep calling a stale closure from the first render.
        textView.onPasteImage = onPasteImage
        context.coordinator.update(
            text: $text,
            activeQuery: $activeQuery,
            pickerActive: pickerActive,
            onSend: onSend,
            onPickerNavigate: onPickerNavigate,
            onPickerCommit: onPickerCommit,
            onPickerDismiss: onPickerDismiss,
            controller: controller
        )

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
        var textBinding: Binding<String>
        var activeQueryBinding: Binding<String?>
        var pickerActive: Bool
        var onSend: () -> Void
        var onPickerNavigate: (Int) -> Void
        var onPickerCommit: () -> Void
        var onPickerDismiss: () -> Void

        weak var textView: MentionNSTextView?
        /// One-shot guard for "focus the composer when the window
        /// first attaches the view." `makeNSView` runs before the
        /// view is in a window so we can't makeFirstResponder there;
        /// `updateNSView` runs again once the hierarchy is wired,
        /// which is when this fires. Subsequent updates are no-ops
        /// so we don't fight the user's own focus changes.
        var didFocusOnce: Bool = false

        init(
            text: Binding<String>,
            activeQuery: Binding<String?>,
            pickerActive: Bool,
            onSend: @escaping () -> Void,
            onPickerNavigate: @escaping (Int) -> Void,
            onPickerCommit: @escaping () -> Void,
            onPickerDismiss: @escaping () -> Void
        ) {
            self.textBinding = text
            self.activeQueryBinding = activeQuery
            self.pickerActive = pickerActive
            self.onSend = onSend
            self.onPickerNavigate = onPickerNavigate
            self.onPickerCommit = onPickerCommit
            self.onPickerDismiss = onPickerDismiss
        }

        func update(
            text: Binding<String>,
            activeQuery: Binding<String?>,
            pickerActive: Bool,
            onSend: @escaping () -> Void,
            onPickerNavigate: @escaping (Int) -> Void,
            onPickerCommit: @escaping () -> Void,
            onPickerDismiss: @escaping () -> Void,
            controller: MentionTextController
        ) {
            self.textBinding = text
            self.activeQueryBinding = activeQuery
            self.pickerActive = pickerActive
            self.onSend = onSend
            self.onPickerNavigate = onPickerNavigate
            self.onPickerCommit = onPickerCommit
            self.onPickerDismiss = onPickerDismiss
            installCommitHandler(controller: controller)
        }

        /// Wire `controller.commit(name:)` to a closure that mutates
        /// the live NSTextView. Called from `makeNSView` and re-called
        /// from `updateNSView` because the SwiftUI struct is transient —
        /// the controller reference gets rebuilt on each render, but
        /// `textView` and `Coordinator` persist.
        func installCommitHandler(controller: MentionTextController) {
            controller.commitMention = { [weak self] name in
                self?.commit(mention: name)
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? MentionNSTextView else { return }
            // Push text back to SwiftUI binding before re-evaluating
            // the mention query, so a subsequent `updateNSView` finds
            // the strings already in sync.
            textBinding.wrappedValue = tv.string
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
            if q != activeQueryBinding.wrappedValue {
                activeQueryBinding.wrappedValue = q
            }
        }

        // MARK: - Key-event interception

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // Picker active: arrow keys navigate, Enter/Tab commit,
            // Esc dismisses. Without this interception arrow keys
            // would move the text caret instead of moving picker
            // selection.
            if pickerActive {
                switch commandSelector {
                case #selector(NSResponder.moveUp(_:)):
                    onPickerNavigate(-1)
                    return true
                case #selector(NSResponder.moveDown(_:)):
                    onPickerNavigate(+1)
                    return true
                case #selector(NSResponder.insertTab(_:)),
                     #selector(NSResponder.insertNewline(_:)):
                    onPickerCommit()
                    return true
                case #selector(NSResponder.cancelOperation(_:)):
                    onPickerDismiss()
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
                onSend()
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
            textBinding.wrappedValue = tv.string
            activeQueryBinding.wrappedValue = nil
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

    /// Set by the SwiftUI wrapper. Called from the overridden `paste(_:)`
    /// when the pasteboard carries image data — routes up to the
    /// composer so the existing image pipeline handles the bytes.
    var onPasteImage: (([NSItemProvider]) -> Void)?

    /// Intercept ⌘V before `NSTextView`'s default paste reads the
    /// pasteboard's `.string` representation (which, for images, is
    /// the source file's path — that's the bug we're fixing).
    ///
    /// Decision tree:
    ///   1. If the pasteboard has a file URL pointing at an image,
    ///      route the URL through `onPasteImage` and stop. We do this
    ///      *before* checking inline image bytes because Finder's
    ///      Copy on an image file puts the file's *icon* on the
    ///      pasteboard as TIFF — without this guard we'd attach a
    ///      32-pixel icon instead of the actual image.
    ///   2. Else, scan for inline image data (PNG, HEIC, JPEG, GIF,
    ///      TIFF) in priority order and route the first match.
    ///   3. Else, fall through to `super.paste(_:)` so plain text
    ///      paste still works.
    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general

        if let provider = imageFileURLProvider(from: pb) {
            onPasteImage?([provider])
            return
        }

        if let provider = inlineImageProvider(from: pb) {
            onPasteImage?([provider])
            return
        }

        super.paste(sender)
    }

    /// Builds an `NSItemProvider` from a file-URL on the pasteboard
    /// when that URL points at an image file. Returns `nil` when the
    /// pasteboard has no file URL or the file isn't an image.
    private func imageFileURLProvider(from pb: NSPasteboard) -> NSItemProvider? {
        guard let urlData = pb.data(forType: .fileURL),
              let url = URL(dataRepresentation: urlData, relativeTo: nil),
              let fileType = UTType(filenameExtension: url.pathExtension),
              fileType.conforms(to: .image)
        else { return nil }

        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.fileURL.identifier,
            visibility: .all
        ) { completion in
            completion(url.dataRepresentation, nil)
            return nil
        }
        return provider
    }

    /// Builds an `NSItemProvider` wrapping inline image bytes from the
    /// pasteboard. GIF wins over raster types so animated frames are
    /// preserved — same priority order as `ChatView.handleProviders`.
    private func inlineImageProvider(from pb: NSPasteboard) -> NSItemProvider? {
        let priority: [UTType] = [.gif, .png, .heic, .jpeg, .tiff]
        for type in priority {
            let pbType = NSPasteboard.PasteboardType(type.identifier)
            guard let data = pb.data(forType: pbType) else { continue }
            let provider = NSItemProvider()
            provider.registerDataRepresentation(
                forTypeIdentifier: type.identifier,
                visibility: .all
            ) { completion in
                completion(data, nil)
                return nil
            }
            return provider
        }
        return nil
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

