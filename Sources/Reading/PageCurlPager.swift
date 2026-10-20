import SwiftUI
import UIKit
import PageCurlKit

/// 基于 PageCurlKit(Metal)的真卷页。
/// 宿主只负责:给出当前页/相邻页的视图、显示目标页,卷页动画交给库。
@MainActor
final class PageCurlPagerController: UIViewController, PageCurlHost {
    typealias Position = Int

    private let count: Int
    private var index: Int
    private let paper: UIColor
    private let makePage: (Int, CGSize) -> AnyView
    private let onIndexChange: (Int) -> Void

    private var curl: PageCurlController<PageCurlPagerController>?
    private var hosts: [Int: UIHostingController<AnyView>] = [:]
    private var shown: UIHostingController<AnyView>?
    private var lastSize: CGSize = .zero

    init(count: Int,
         index: Int,
         paper: UIColor,
         makePage: @escaping (Int, CGSize) -> AnyView,
         onIndexChange: @escaping (Int) -> Void) {
        self.count = count
        self.index = index
        self.paper = paper
        self.makePage = makePage
        self.onIndexChange = onIndexChange
        super.init(nibName: nil, bundle: nil)
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

        let left = UISwipeGestureRecognizer(target: self, action: #selector(swipeLeft))
        left.direction = .left
        view.addGestureRecognizer(left)

        let right = UISwipeGestureRecognizer(target: self, action: #selector(swipeRight))
        right.direction = .right
        view.addGestureRecognizer(right)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard view.bounds.size != lastSize, view.bounds.size.width > 1 else { return }
        lastSize = view.bounds.size
        hosts.removeAll()
        shown = nil
        curl?.invalidate()
        show(index, notify: false)
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
        let host = UIHostingController(rootView: makePage(slot, view.bounds.size))
        host.view.backgroundColor = paper
        host.view.frame = view.bounds
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
    let makePage: (Int, CGSize) -> AnyView

    func makeUIViewController(context: Context) -> PageCurlPagerController {
        PageCurlPagerController(count: count,
                                index: index,
                                paper: paper,
                                makePage: makePage,
                                onIndexChange: { newValue in
            if index != newValue { index = newValue }
        })
    }

    func updateUIViewController(_ controller: PageCurlPagerController, context: Context) {
        controller.syncExternal(index: index)
    }
}
