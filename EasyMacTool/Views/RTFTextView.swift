import AppKit
import SwiftUI

/// 用 NSTextView 渲染 RTF 富文本的 SwiftUI 视图。
/// 当 ClipboardItem 有 rtfData 时用此视图还原颜色/字体样式；
/// 否则回退到普通 Text 渲染。
struct RTFTextView: NSViewRepresentable {
    let rtfData: Data?
    let plainText: String
    let font: NSFont

    final class Coordinator {
        var lastRTFData: Data?
        var lastPlainText: String?
        var lastFontName: String?
        var lastFontSize: CGFloat?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        // 修复预览打开时滚动条闪烁：系统滚动条为 legacy（常驻占位）样式时，
        // autohidesScrollers 会让滚动条随布局反复显隐，叠加预览的 spring 缩放
        // 动画即表现为「滚动条闪烁」。改用 overlay 滚动条（悬浮不占布局、
        // 平滑淡入淡出），消除该闪烁。
        scrollView.scrollerStyle = .overlay

        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
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
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let coordinator = context.coordinator
        let contentUnchanged = coordinator.lastRTFData == rtfData &&
            coordinator.lastPlainText == plainText
        let fontUnchanged = coordinator.lastFontName == font.fontName &&
            coordinator.lastFontSize == font.pointSize
        guard !(contentUnchanged && fontUnchanged) else { return }

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
        coordinator.lastRTFData = rtfData
        coordinator.lastPlainText = plainText
        coordinator.lastFontName = font.fontName
        coordinator.lastFontSize = font.pointSize
    }
}
