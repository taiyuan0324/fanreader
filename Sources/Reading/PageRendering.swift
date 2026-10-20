import SwiftUI
import UIKit
import CoreText

/// 分页器:与渲染共用同一份 NSAttributedString,保证切页位置与屏幕完全一致。
enum Paginator {
    /// 后台线程分页:只回传 NSRange 数组,主线程零排版
    static func rangesAsync(text: String,
                            attributes: [NSAttributedString.Key: Any],
                            size: CGSize) async -> [NSRange] {
        let attributed = NSAttributedString(string: text, attributes: attributes)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: ranges(attributed: attributed, size: size))
            }
        }
    }

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

// MARK: - CoreText 单页视图(位图渲染 + 高亮路径)

/// 性能要点:
/// 1. 文字在后台线程用 UIGraphicsImageRenderer 渲染成位图,直接赋给 layer.contents,
///    主线程零 drawRect;高亮换段不再触发文字重绘。
/// 2. 高亮用 CAShapeLayer 纯几何路径,微秒级更新。
/// 3. 行信息(CTLine/origin)随位图一起缓存,命中测试不再重复排版。
final class CoreTextPageView: UIView {
    var attributedText: NSAttributedString? {
        didSet {
            guard oldValue != attributedText else { return }
            scheduleBitmapRender()
        }
    }
    var highlightRange: NSRange? {
        didSet {
            guard oldValue != highlightRange else { return }
            updateHighlightPath()
        }
    }
    var highlightColor: UIColor = UIColor(red: 0.965, green: 0.918, blue: 0.804, alpha: 1) {
        didSet { highlightLayer.fillColor = highlightColor.cgColor }
    }

    var onSingleTap: ((CGFloat) -> Void)?
    var onDoubleTap: ((Int) -> Void)?

    private let textLayer = CALayer()
    private let highlightLayer = CAShapeLayer()

    private var lines: [CTLine] = []
    private var origins: [CGPoint] = []      // CoreText 坐标(左下原点)
    private var renderToken = 0

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
        clipsToBounds = false

        let scale = UIScreen.main.scale
        textLayer.contentsScale = scale
        textLayer.contentsGravity = .topLeft
        textLayer.masksToBounds = true
        highlightLayer.contentsScale = scale

        layer.addSublayer(highlightLayer)
        layer.addSublayer(textLayer)

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
        textLayer.frame = bounds
        highlightLayer.frame = bounds
        scheduleBitmapRender()
    }

    // MARK: - 后台位图渲染

    private func scheduleBitmapRender() {
        renderToken &+= 1
        let token = renderToken

        guard let text = attributedText,
              bounds.width > 1, bounds.height > 1,
              text.length > 0 else {
            textLayer.contents = nil
            lines = []
            origins = []
            updateHighlightPath()
            return
        }

        let size = bounds.size
        let scale = UIScreen.main.scale
        let safeText = text

        Task.detached(priority: .userInitiated) { [weak self] in
            var renderedLines: [CTLine] = []
            var renderedOrigins: [CGPoint] = []

            let format = UIGraphicsImageRendererFormat()
            format.opaque = false
            format.scale = scale
            let renderer = UIGraphicsImageRenderer(size: size, format: format)
            let image = renderer.image { context in
                let cg = context.cgContext
                cg.clear(CGRect(origin: .zero, size: size))

                // CoreText 是左下原点,翻转到 UIKit 坐标
                cg.translateBy(x: 0, y: size.height)
                cg.scaleBy(x: 1, y: -1)

                let framesetter = CTFramesetterCreateWithAttributedString(safeText)
                let path = CGPath(rect: CGRect(origin: .zero, size: size), transform: nil)
                let frame = CTFramesetterCreateFrame(framesetter,
                                                     CFRange(location: 0, length: 0),
                                                     path, nil)
                CTFrameDraw(frame, cg)

                let ls = (CTFrameGetLines(frame) as? [CTLine]) ?? []
                var pts = [CGPoint](repeating: .zero, count: ls.count)
                if !ls.isEmpty {
                    CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &pts)
                }
                renderedLines = ls
                renderedOrigins = pts
            }

            await MainActor.run {
                self?.apply(image: image, lines: renderedLines, origins: renderedOrigins, token: token)
            }
        }
    }

    @MainActor
    private func apply(image: UIImage, lines: [CTLine], origins: [CGPoint], token: Int) {
        guard token == renderToken else { return }
        textLayer.frame = bounds
        textLayer.contents = image.cgImage
        self.lines = lines
        self.origins = origins
        updateHighlightPath()
    }

    // MARK: - 高亮(纯几何,不碰文字)

    private func updateHighlightPath() {
        guard let range = highlightRange,
              range.length > 0,
              lines.count == origins.count,
              !lines.isEmpty else {
            highlightLayer.path = nil
            return
        }

        let path = UIBezierPath()
        for (index, line) in lines.enumerated() {
            let lineRange = CTLineGetStringRange(line)
            let start = max(lineRange.location, range.location)
            let end = min(lineRange.location + lineRange.length, range.location + range.length)
            guard start < end else { continue }

            let xStart = CTLineGetOffsetForStringIndex(line, start, nil)
            let xEnd = CTLineGetOffsetForStringIndex(line, end, nil)
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            CTLineGetTypographicBounds(line, &ascent, &descent, nil)

            let origin = origins[index]
            let top = bounds.height - origin.y - ascent
            path.append(UIBezierPath(rect: CGRect(x: origin.x + xStart,
                                                  y: top,
                                                  width: max(0, xEnd - xStart),
                                                  height: ascent + descent)))
        }
        highlightLayer.frame = bounds
        highlightLayer.path = path.cgPath
        highlightLayer.fillColor = highlightColor.cgColor
    }

    // MARK: - 命中测试(用缓存行,零排版)

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

            if flippedY <= origin.y + ascent, flippedY >= origin.y - descent {
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
        if view.attributedText != attributedText {
            view.attributedText = attributedText
        }
        view.highlightRange = highlightRange
    }
}
