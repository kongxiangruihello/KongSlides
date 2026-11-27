import AppKit
import SwiftUI

private final class ListTextView: NSTextView {
    var markers: [(offset: Int, text: String, x: CGFloat, attributes: [NSAttributedString.Key: Any])] = []

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !markers.isEmpty, let layoutManager, let textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let origin = textContainerOrigin
        for marker in markers {
            let baseline: CGFloat
            if marker.offset < (textStorage?.length ?? 0) {
                let glyph = layoutManager.glyphIndexForCharacter(at: marker.offset)
                let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                baseline = line.minY + layoutManager.location(forGlyphAt: glyph).y
            } else {
                let line = layoutManager.extraLineFragmentRect
                let font = marker.attributes[.font] as? NSFont
                baseline = line.minY + (font?.ascender ?? 0)
            }
            let font = marker.attributes[.font] as? NSFont
            let point = NSPoint(x: origin.x + marker.x, y: origin.y + baseline - (font?.ascender ?? 0))
            (marker.text as NSString).draw(at: point, withAttributes: marker.attributes)
        }
    }
}

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
            editor.select(view.selectedRanges.map(\.rangeValue)
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
        let view = ListTextView(frame: scroll.bounds)
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        scroll.documentView = view
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
        guard let view = scroll.documentView as? ListTextView, let storage = view.textStorage, !view.hasMarkedText(),
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
        let markerAttributes: [NSAttributedString.Key: Any] = [
            .font: typing[.font] ?? NSFont.systemFont(ofSize: object.fontSize * scale),
            .foregroundColor: Palette.color(object.color)
        ]
        var offset = 0
        view.markers = zip(object.text.components(separatedBy: "\n"), object.paragraphStyles).compactMap { line, paragraph in
            defer { offset += line.utf16.count + 1 }
            return paragraph.bullet.map { (offset, $0.marker, SlideText.listMarkerInset(paragraph, scale: scale), markerAttributes) }
        }
        view.needsDisplay = true
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
