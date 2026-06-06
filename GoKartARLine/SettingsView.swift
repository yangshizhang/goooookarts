import SwiftUI
import CoreLocation

struct SettingsView: View {
    @Binding var settings: ARLineSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("行车线样式")) {
                    Slider(value: $settings.opacity, in: 0.15...1.0) { Text("透明度") }
                    HStack { Text("透明度"); Spacer(); Text(String(format: "%.2f", settings.opacity)).foregroundStyle(.secondary) }
                    Slider(value: $settings.width, in: 0.2...1.2) { Text("宽度") }
                    HStack { Text("宽度"); Spacer(); Text(String(format: "%.2f m", settings.width)).foregroundStyle(.secondary) }
                    Slider(value: $settings.brightness, in: 0.2...1.0) { Text("亮度") }
                    Toggle("禁用深度测试（提升帧率）", isOn: $settings.disableDepthTest)
                }

                Section(header: Text("传感器与性能")) {
                    Picker("GPS精度", selection: $settings.gpsDesiredAccuracy) {
                        Text("导航级").tag(kCLLocationAccuracyBestForNavigation)
                        Text("最佳").tag(kCLLocationAccuracyBest)
                        Text("10米").tag(kCLLocationAccuracyNearestTenMeters)
                    }
                    Toggle("省电模式（AR 30fps）", isOn: $settings.powerSavingMode)
                }

                Section(header: Text("单位")) {
                    Toggle("公制单位", isOn: $settings.metricUnits)
                }

                Section(header: Text("安全")) {
                    Text("请只在封闭赛道使用。手机必须固定牢靠，AR提示不能替代驾驶判断。")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        }
    }
}
