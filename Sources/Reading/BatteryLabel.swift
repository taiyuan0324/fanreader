import SwiftUI
import UIKit

/// 页眉右侧的电量百分比(iOS 不允许读其它 App 的电量图标,这里自绘数字)
struct BatteryLabel: View {
    @State private var level: Float = UIDevice.current.batteryLevel
    @State private var charging = false

    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: charging ? "battery.100.bolt" : iconName)
                .font(.system(size: 11))
            Text(text)
                .font(.system(size: 10))
                .monospacedDigit()
        }
        .onAppear {
            UIDevice.current.isBatteryMonitoringEnabled = true
            refresh()
        }
        .onReceive(timer) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)) { _ in refresh() }
    }

    private var text: String {
        level < 0 ? "--%" : "\(Int((level * 100).rounded()))%"
    }

    private var iconName: String {
        guard level >= 0 else { return "battery.0" }
        switch level {
        case ..<0.15: return "battery.0"
        case ..<0.4: return "battery.25"
        case ..<0.7: return "battery.50"
        case ..<0.95: return "battery.75"
        default: return "battery.100"
        }
    }

    private func refresh() {
        level = UIDevice.current.batteryLevel
        charging = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
    }
}
