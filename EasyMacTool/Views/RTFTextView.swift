import AppKit
import SwiftUI

/// 用 NSTextView 渲染 RTF 富文本的 SwiftUI 视图。
/// 当 ClipboardItem 有 rtfData 时用此视图还原颜色/字体样式；
/// 否则回退到普通 Text 渲染。
struct RTFTextView: NSViewRepresentable {
    let rtfData: Data?
    let plainText: String
    let font: NSFont

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.lineFragmentPadding = 4
        textView.font = font
        textView.textColor = .labelColor
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let textView = scrollView.documentView as! NSTextView
        textView.font = font
        textView.textColor = .labelColor

        if let rtfData = rtfData,
           let attributed = try? NSAttributedString(
               data: rtfData,
               options: [.documentType: NSAttributedString.DocumentType.rtf],
               documentAttributes: nil) {
            textView.textStorage?.setAttributedString(attributed)
        } else {
            textView.string = plainText
        }
    }
}
