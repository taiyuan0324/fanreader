import SwiftUI
import UIKit
import PageCurlKit

/// 基于 PageCurlKit(Metal)的真卷页。
/// 宿主只负责:给出当前页/相邻页的视图、显示目标页,卷页动画交给库。
@MainActor
final class PageCurlPagerController: UIViewController, PageCurlHost, UIGestureRecognizerDelegate {
    typealias Position = Int

    private let count: Int
    private var index: Int
    private let paper: UIColor
    private var makePage: (Int) -> AnyView
    private let onIndexChange: (Int) -> Void
    private(set) var version: Int = -1

    private var curl: PageCurlController<PageCurlPagerController>?
    private var hosts: [Int: UIHostingController<AnyView>] = [:]
    private var shown: UIHostingController<AnyView>?
    private var lastSize: CGSize = .zero

    init(count: Int,
         index: Int,
         paper: UIColor,
         makePage: @escaping (Int) -> AnyView,
         onIndexChange: @escaping (Int) -> Void) {
        self.count = count
        self.index = index
        self.paper = paper
        self.makePage = makePage
        self.onIndexChange = onIndexChange
        super.init(nibName: nil, bundle: nil)
    }

    /// 内容变了(分页重建/换章/改字号):丢掉缓存的页面视图并重建当前页
    func reload(makePage: @escaping (Int) -> AnyView, version: Int) {
        guard version != self.version else { return }
        self.version = version
        self.makePage = makePage
        for host in hosts.values {
            host.willMove(toParent: nil)
            host.view.removeFromSuperview()
            host.removeFromParent()
        }
        hosts.removeAll()
        shown = nil
        curl?.invalidate()
        show(index, notify: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = paper
        view.clipsToBounds = true

        curl = PageCurlController(host: self, container: view)
        curl?.warmUp()

        show(index, notify: false)

        // 关键:库会在容器里插一个铺满全屏的 sizeSentinel,叠在页面之上,
        // 不禁用交互的话,所有触摸都会被它吃掉(单击/滑动全部失效)
        disableNonPageInteraction()

        let left = UISwipeGestureRecognizer(target: self, action: #selector(swipeLeft))
        left.direction = .left
        view.addGestureRecognizer(left)

        let right = UISwipeGestureRecognizer(target: self, action: #selector(swipeRight))
        right.direction = .right
        view.addGestureRecognizer(right)

        // 单击左右 30% 区域 = 带卷页动画翻页;双击留给 SwiftUI(定位朗读)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self
        view.addGestureRecognizer(tap)
    }

    private var lastTapTime: Date = .distantPast

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let now = Date()
        let isDouble = now.timeIntervalSince(lastTapTime) < 0.28
        lastTapTime = now
        // 第二击交给 SwiftUI 的双击手势(定位朗读),这里不翻页
        if isDouble { return }

        let location = gesture.location(in: view)
        let fraction = view.bounds.width > 1 ? location.x / view.bounds.width : 0.5
        if fraction < 0.3 {
            curl?.turn(forward: false, isSpread: false)
        } else if fraction > 0.7 {
            curl?.turn(forward: true, isSpread: false)
        }
        // 中间 40% 不处理:单击呼出/收起工具条由 SwiftUI 处理
    }

    private func disableNonPageInteraction() {
        let pageViews = hosts.values.map { ObjectIdentifier($0.view) }
            + (shown.map { [ObjectIdentifier($0.view)] } ?? [])
        for subview in view.subviews {
            if !pageViews.contains(ObjectIdentifier(subview)) {
                subview.isUserInteractionEnabled = false
            }
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard view.bounds.size != lastSize, view.bounds.size.width > 1 else { return }
        lastSize = view.bounds.size
        hosts.removeAll()
        shown = nil
        curl?.invalidate()
        show(index, notify: false)
        disableNonPageInteraction()
    }

    @objc private func swipeLeft() {
        curl?.turn(forward: true, isSpread: false)
    }

    @objc private func swipeRight() {
        curl?.turn(forward: false, isSpread: false)
    }

    /// 外部(朗读跟随/目录跳转)改页码时,直接切换,不做卷页
    func syncExternal(index newIndex: Int) {
        guard newIndex != index else { return }
        show(newIndex, notify: false)
    }

    // MARK: - 页面

    private func pageHost(at slot: Int) -> UIHostingController<AnyView> {
        if let cached = hosts[slot] { return cached }
        let host = UIHostingController(rootView: makePage(slot))
        host.view.backgroundColor = paper
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addChild(host)
        host.didMove(toParent: self)
        hosts[slot] = host
        return host
    }

    private func show(_ newIndex: Int, notify: Bool = true) {
        let clamped = max(0, min(newIndex, count - 1))
        let host = pageHost(at: clamped)
        if shown?.view !== host.view {
            shown?.view.removeFromSuperview()
            host.view.frame = view.bounds
            view.insertSubview(host.view, at: 0)
            shown = host
        }
        index = clamped
        disableNonPageInteraction()
        curl?.prefetch()
        if notify { onIndexChange(clamped) }
    }

    // MARK: - PageCurlHost

    var currentPosition: Int { index }

    func canTurn() -> Bool { true }

    var paperColor: UIColor { paper }

    func currentSpreadView() -> UIView? { shown?.view }

    func neighbourSpreadView(forward: Bool) -> UIView? {
        let target = forward ? index + 1 : index - 1
        guard target >= 0, target < count else { return nil }
        let host = pageHost(at: target)
        host.view.frame = view.bounds
        return host.view
    }

    func showTarget(forward: Bool) async -> Bool {
        let target = forward ? index + 1 : index - 1
        guard target >= 0, target < count else { return false }
        show(target)
        return true
    }

    func enqueue(_ step: @escaping @MainActor () async -> Void) {
        Task { await step() }
    }
}

/// SwiftUI 包装
struct PageCurlPager: UIViewControllerRepresentable {
    let count: Int
    @Binding var index: Int
    let paper: UIColor
    /// 内容变更令牌:页数 + 章节 + 排版尺寸,任一变化都要重建页面视图
    let version: Int
    let makePage: (Int) -> AnyView

    func makeUIViewController(context: Context) -> PageCurlPagerController {
        let controller = PageCurlPagerController(count: count,
                                                 index: index,
                                                 paper: paper,
                                                 makePage: makePage,
                                                 onIndexChange: { newValue in
            if index != newValue { index = newValue }
        })
        // 首次进入也走一次 reload,确保用最新闭包
        context.coordinator.version = version
        return controller
    }

    func updateUIViewController(_ controller: PageCurlPagerController, context: Context) {
        if controller.version != version || context.coordinator.version != version {
            context.coordinator.version = version
            controller.reload(makePage: makePage, version: version)
        }
        controller.syncExternal(index: index)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator { var version = -1 }
}
