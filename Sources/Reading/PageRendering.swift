import SwiftUI
import UIKit
import CoreText

/// 分页器:与渲染共用同一份 NSAttributedString,保证切页位置与屏幕完全一致。
enum Paginator {
    static func ranges(attributed: NSAttributedString, size: CGSize) -> [NSRange] {
        guard attributed.length > 0, size.width > 1, size.height > 1 else { return [] }

        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: CGRect(origin: .zero, size: size), transform: nil)

        var result: [NSRange] = []
        var location = 0
        while location < attributed.length {
            let frame = CTFramesetterCreateFrame(framesetter,
                                                 CFRange(location: location, length: 0),
                                                 path, nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else { break }
            result.append(NSRange(location: visible.location, length: visible.length))
            location = visible.location + visible.length
        }
        return result
    }

    static func pages(attributed: NSAttributedString, size: CGSize) -> [NSAttributedString] {
        let ranges = ranges(attributed: attributed, size: size)
        guard !ranges.isEmpty else { return [attributed] }
        return ranges.map { attributed.attributedSubstring(from: $0) }
    }

    static func pageIndex(containing needle: String, in pages: [NSAttributedString]) -> Int? {
        let compact = needle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else { return nil }
        return pages.firstIndex { $0.string.contains(compact) }
    }
}

/// 用 CoreText 绘制单页:视觉与分页算法同源,不会出现"最后一页溢出"。
final class CoreTextPageView: UIView {
    var attributedText: NSAttributedString? {
        didSet { setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .clear
        isOpaque = false
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(),
              let text = attributedText,
              text.length > 0 else { return }

        context.textMatrix = .identity
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)

        let path = CGPath(rect: CGRect(origin: .zero, size: bounds.size), transform: nil)
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let frame = CTFramesetterCreateFrame(framesetter,
                                             CFRange(location: 0, length: 0),
                                             path, nil)
        CTFrameDraw(frame, context)
    }
}

struct CoreTextPage: UIViewRepresentable {
    let attributedText: NSAttributedString

    func makeUIView(context: Context) -> CoreTextPageView {
        let view = CoreTextPageView()
        view.attributedText = attributedText
        return view
    }

    func updateUIView(_ uiView: CoreTextPageView, context: Context) {
        if uiView.attributedText !== attributedText {
            uiView.attributedText = attributedText
        }
    }
}

/// 上下滚动模式:整章一个可滚动文本视图,属性与分页模式一致。
struct ScrollChapterView: UIViewRepresentable {
    let attributedText: NSAttributedString
    let backgroundColor: UIColor
    @Binding var scrollOffset: CGFloat

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = false
        view.showsVerticalScrollIndicator = false
        view.textContainerInset = UIEdgeInsets(top: 12, left: 0, bottom: 40, right: 0)
        view.backgroundColor = backgroundColor
        view.attributedText = attributedText
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        view.backgroundColor = backgroundColor
        if view.attributedText != attributedText {
            view.attributedText = attributedText
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ScrollChapterView

        init(_ parent: ScrollChapterView) {
            self.parent = parent
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            parent.scrollOffset = scrollView.contentOffset.y
        }
    }
}
