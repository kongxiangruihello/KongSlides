import AppKit
import SwiftUI

struct CanvasTextEditor: NSViewRepresentable {
    let object: SlideObject
    let scale: CGFloat
    let selectAll: Bool
    let edit: (String) -> Void
    let select: ([Range<Int>]) -> Void
    let finish: () -> Void

    final class Coordinator: NSObject, NSTextViewDelegate {
        var editor: CanvasTextEditor
        var updating = false
        var rendered: SlideObject?
        var scale: CGFloat?

        init(_ editor: CanvasTextEditor) { self.editor = editor }

        func textDidChange(_ notification: Notification) {
            guard !updating, let view = notification.object as? NSTextView else { return }
            editor.edit(view.string)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !updating, let view = notification.object as? NSTextView else { return }
            editor.select(view.selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
                .map { $0.location..<NSMaxRange($0) }.sorted { $0.lowerBound < $1.lowerBound })
        }

        func textDidEndEditing(_ notification: Notification) {
            guard !updating else { return }
            editor.finish()
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            editor.finish()
            return true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        view.drawsBackground = false
        view.isRichText = false
        view.allowsUndo = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.delegate = context.coordinator
        view.setAccessibilityLabel("编辑幻灯片文本")
        updateNSView(scroll, context: context)
        DispatchQueue.main.async { [weak view] in
            guard let view, let window = view.window else { return }
            window.makeFirstResponder(view)
            if selectAll { view.selectAll(nil) }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.editor = self
        guard let view = scroll.documentView as? NSTextView, let storage = view.textStorage, !view.hasMarkedText(),
              coordinator.rendered != object || coordinator.scale != scale else { return }
        coordinator.updating = true
        defer { coordinator.updating = false }
        coordinator.rendered = object
        coordinator.scale = scale
        let typing = SlideText.editorAttributes(object.baseTextStyle, fallback: object, scale: scale)
        let inset = object.textLayout?.insets ?? .init()
        view.textContainerInset = NSSize(width: inset.left * scale, height: inset.top * scale)
        view.textContainer?.lineFragmentPadding = 0
        let previous = view.selectedRanges
        let styled = SlideText.editableText(object, scale: scale)
        if view.string == object.text {
            storage.beginEditing()
            styled.enumerateAttributes(in: NSRange(location: 0, length: styled.length)) { attributes, range, _ in
                storage.setAttributes(attributes, range: range)
            }
            storage.endEditing()
        } else {
            storage.setAttributedString(styled)
        }
        let selections = previous.filter { NSMaxRange($0.rangeValue) <= storage.length }
        view.selectedRanges = selections.isEmpty ? [NSValue(range: NSRange(location: 0, length: 0))] : selections
        if storage.length == 0 { view.typingAttributes = typing }
    }
}
