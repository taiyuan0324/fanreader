import SwiftUI

/// 自研翻页:双面 3D 翻转。
/// 相比系统 UIPageViewController,这里可以完全控制:整屏覆盖、正反面同色、玻璃高光与阴影。
struct FlipPager: View {
    let count: Int
    @Binding var index: Int
    let content: (Int) -> AnyView
    /// 页面底色(正反面一致)
    let pageBackground: Color

    @State private var progress: CGFloat = 0
    @State private var forward = true
    @State private var animating = false

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let angle = -180 * progress * (forward ? 1 : -1)

            ZStack {
                // 下层:静止的目标页
                page(underIndex)

                // 翻转层:正面(当前页) + 背面(目标页镜像)
                ZStack {
                    page(topIndex)
                        .opacity(progress < 0.5 ? 1 : 0)

                    page(underIndex)
                        .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
                        .overlay(pageBackground.opacity(0.06))
                        .opacity(progress >= 0.5 ? 1 : 0)
                }
                .overlay(shading)
                .rotation3DEffect(.degrees(angle),
                                  axis: (x: 0, y: 1, z: 0),
                                  anchor: forward ? .leading : .trailing,
                                  perspective: 0.28)
                .shadow(color: .black.opacity(0.28 * progress),
                        radius: 22 * progress + 2,
                        x: (forward ? 1 : -1) * 16 * progress)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            .contentShape(Rectangle())
            .onAppear {
                // 截图调试:定格在翻页中途
                if ProcessInfo.processInfo.arguments.contains("-flipMid") {
                    forward = true
                    progress = 0.45
                }
            }
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        guard !animating else { return }
                        let dx = value.translation.width
                        if progress == 0, abs(dx) > 10 {
                            forward = dx < 0
                        }
                        let limit = forward ? canGoForward : canGoBackward
                        guard limit else { return }
                        progress = min(1, abs(dx) / width)
                    }
                    .onEnded { _ in
                        guard !animating, progress > 0 else { return }
                        let commit = progress > 0.3 && (forward ? canGoForward : canGoBackward)
                        animating = true
                        withAnimation(.easeOut(duration: 0.32)) {
                            progress = commit ? 1 : 0
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) {
                            if commit {
                                index += forward ? 1 : -1
                            }
                            progress = 0
                            animating = false
                        }
                    }
            )
        }
    }

    // MARK: - 计算

    private var topIndex: Int {
        forward ? index : max(index - 1, 0)
    }

    private var underIndex: Int {
        forward ? min(index + 1, count - 1) : max(index - 1, 0)
    }

    private var canGoForward: Bool { index + 1 < count }
    private var canGoBackward: Bool { index > 0 }

    private func page(_ slot: Int) -> some View {
        content(max(0, min(slot, count - 1)))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 翻动时的明暗与玻璃高光
    private var shading: some View {
        ZStack {
            LinearGradient(
                colors: [.black.opacity(0.22 * progress), .clear],
                startPoint: forward ? .trailing : .leading,
                endPoint: forward ? .leading : .trailing
            )

            LinearGradient(
                colors: [.white.opacity(0.0), .white.opacity(0.28 * progress), .white.opacity(0.0)],
                startPoint: forward ? .leading : .trailing,
                endPoint: forward ? .trailing : .leading
            )
        }
        .allowsHitTesting(false)
    }
}
