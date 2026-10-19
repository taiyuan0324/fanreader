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

// MARK: - CoreText 单页视图(高亮 + 命中测试)

/// 用 CoreText 自绘单页:排版与分页算法同源,不会错位;
/// 高亮按行矩形填充,双击用 CTLine 反查字符下标。

final class CoreTextPageView: UIView {
    var attributedText: NSAttributedString? {
        didSet { rebuild() }
    }
    var highlightRange: NSRange? {
        didSet {
            if oldValue != highlightRange { setNeedsDisplay() }
        }
    }
    var highlightColor: UIColor = UIColor.systemYellow.withAlphaComponent(0.3) {
        didSet { setNeedsDisplay() }
    }

    var onSingleTap: ((CGFloat) -> Void)?
    var onDoubleTap: ((Int) -> Void)?

    private var framesetter: CTFramesetter?
    private var frameRef: CTFrame?
    private var lines: [CTLine] = []
    private var origins: [CGPoint] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDouble(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingle(_:)))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(singleTap)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        rebuild()
    }

    private func rebuild() {
        guard let text = attributedText, text.length > 0 else {
            frameRef = nil; lines = []; origins = []
            setNeedsDisplay()
            return
        }
        let setter = CTFramesetterCreateWithAttributedString(text)
        let path = CGPath(rect: CGRect(origin: .zero, size: bounds.size), transform: nil)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
        framesetter = setter
        frameRef = frame
        lines = (CTFrameGetLines(frame) as? [CTLine]) ?? []

        var points = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &points)
        origins = points
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), let frame = frameRef else { return }

        context.textMatrix = .identity
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)

        drawHighlight(in: context)

        CTFrameDraw(frame, context)
    }

    private func drawHighlight(in context: CGContext) {
        guard let range = highlightRange, range.length > 0, lines.count == origins.count else { return }

        context.saveGState()
        context.setFillColor(highlightColor.cgColor)

        for (index, line) in lines.enumerated() {
            let lineRange = CTLineGetStringRange(line)
            let lineStart = lineRange.location
            let lineEnd = lineRange.location + lineRange.length
            let start = max(lineStart, range.location)
            let end = min(lineEnd, range.location + range.length)
            guard start < end else { continue }

            let xStart = CTLineGetOffsetForStringIndex(line, start, nil)
            let xEnd = CTLineGetOffsetForStringIndex(line, end, nil)
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            CTLineGetTypographicBounds(line, &ascent, &descent, nil)

            let origin = origins[index]
            let lineRect = CGRect(x: origin.x + xStart,
                                  y: origin.y - descent,
                                  width: max(0, xEnd - xStart),
                                  height: ascent + descent)
            context.fill(lineRect)
        }
        context.restoreGState()
    }

    // MARK: - 命中测试

    @objc private func handleDouble(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        guard let index = characterIndex(at: point) else { return }
        onDoubleTap?(index)
    }

    @objc private func handleSingle(_ gesture: UITapGestureRecognizer) {
        let x = gesture.location(in: self).x
        let fraction = bounds.width > 1 ? x / bounds.width : 0.5
        onSingleTap?(min(max(fraction, 0), 1))
    }

    private func characterIndex(at point: CGPoint) -> Int? {
        guard lines.count == origins.count, !lines.isEmpty else { return nil }
        let flippedY = bounds.height - point.y

        var bestIndex: Int?
        var bestDistance = CGFloat.greatestFiniteMagnitude

        for (index, line) in lines.enumerated() {
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            CTLineGetTypographicBounds(line, &ascent, &descent, nil)
            let origin = origins[index]
            let top = origin.y + ascent
            let bottom = origin.y - descent

            if flippedY <= top && flippedY >= bottom {
                let localX = max(0, point.x - origin.x)
                let idx = CTLineGetStringIndexForPosition(line, CGPoint(x: localX, y: 0))
                if idx != kCFNotFound { return idx }
            }
            let distance = abs(flippedY - origin.y)
            if distance < bestDistance {
                bestDistance = distance
                let localX = max(0, point.x - origin.x)
                let idx = CTLineGetStringIndexForPosition(line, CGPoint(x: localX, y: 0))
                if idx != kCFNotFound { bestIndex = idx }
            }
        }
        return bestIndex
    }
}

struct CoreTextPage: UIViewRepresentable {
    let attributedText: NSAttributedString
    let highlightRange: NSRange?
    let highlightColor: UIColor
    let onSingleTap: (CGFloat) -> Void
    let onDoubleTap: (Int) -> Void

    func makeUIView(context: Context) -> CoreTextPageView {
        let view = CoreTextPageView()
        view.onSingleTap = onSingleTap
        view.onDoubleTap = onDoubleTap
        view.highlightColor = highlightColor
        view.attributedText = attributedText
        view.highlightRange = highlightRange
        return view
    }

    func updateUIView(_ view: CoreTextPageView, context: Context) {
        view.onSingleTap = onSingleTap
        view.onDoubleTap = onDoubleTap
        view.highlightColor = highlightColor
        if view.attributedText !== attributedText {
            view.attributedText = attributedText
        }
        view.highlightRange = highlightRange
    }
}
