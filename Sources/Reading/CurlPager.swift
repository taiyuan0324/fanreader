import SwiftUI
import UIKit

/// 带页码的宿主控制器
final class IndexedHostingController: UIHostingController<AnyView> {
    let pageIndex: Int

    init(index: Int, rootView: AnyView) {
        self.pageIndex = index
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// 仿真翻页(UIPageViewController 的 pageCurl)。
/// 只负责卷页过渡与页码回调,页面内容/手势/高亮仍由外部提供。
struct CurlPager: UIViewControllerRepresentable {
    let count: Int
    @Binding var index: Int
    /// 卷页需要不透明页面,否则翻动时会透底
    let pageBackground: UIColor
    let content: (Int) -> AnyView

    func makeCoordinator() -> Coordinator {
        Coordinator(count: count, index: index, background: pageBackground, content: content)
    }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pager = UIPageViewController(transitionStyle: .pageCurl,
                                         navigationOrientation: .horizontal,
                                         options: nil)
        pager.dataSource = context.coordinator
        pager.delegate = context.coordinator
        pager.isDoubleSided = false
        pager.view.backgroundColor = pageBackground
        pager.view.isOpaque = true

        let coordinator = context.coordinator
        coordinator.onIndexChange = { newIndex in
            if self.index != newIndex { self.index = newIndex }
        }

        if let first = coordinator.controller(for: index) {
            pager.setViewControllers([first], direction: .forward, animated: false)
            coordinator.currentIndex = index
        }
        return pager
    }

    func updateUIViewController(_ pager: UIPageViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.count = count
        coordinator.background = pageBackground
        coordinator.content = content

        guard coordinator.currentIndex != index,
              let controller = coordinator.controller(for: index) else { return }

        let forward = index > coordinator.currentIndex
        coordinator.currentIndex = index
        pager.setViewControllers([controller],
                                 direction: forward ? .forward : .reverse,
                                 animated: true)
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var count: Int
        var currentIndex: Int
        var background: UIColor
        var content: (Int) -> AnyView
        var onIndexChange: ((Int) -> Void)?

        init(count: Int, index: Int, background: UIColor, content: @escaping (Int) -> AnyView) {
            self.count = count
            self.currentIndex = index
            self.background = background
            self.content = content
        }

        func controller(for pageIndex: Int) -> UIViewController? {
            guard pageIndex >= 0, pageIndex < count else { return nil }
            let host = IndexedHostingController(index: pageIndex, rootView: content(pageIndex))
            host.view.backgroundColor = background
            return host
        }

        func pageViewController(_ pager: UIPageViewController,
                                viewControllerBefore viewController: UIViewController) -> UIViewController? {
            guard let current = viewController as? IndexedHostingController else { return nil }
            return controller(for: current.pageIndex - 1)
        }

        func pageViewController(_ pager: UIPageViewController,
                                viewControllerAfter viewController: UIViewController) -> UIViewController? {
            guard let current = viewController as? IndexedHostingController else { return nil }
            return controller(for: current.pageIndex + 1)
        }

        func pageViewController(_ pager: UIPageViewController,
                                didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController],
                                transitionCompleted completed: Bool) {
            guard completed,
                  let current = pager.viewControllers?.first as? IndexedHostingController else { return }
            currentIndex = current.pageIndex
            onIndexChange?(current.pageIndex)
        }
    }
}
