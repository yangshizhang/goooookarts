import SwiftUI
import CoreLocation

struct SettingsView: View {
    @Binding var settings: ARLineSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("行车线样式")) {
                    Slider(value: $settings.opacity, in: 0.15...1.0) { Text("透明度") }.liquidGlassControl()
                    HStack { Text("透明度"); Spacer(); Text(String(format: "%.2f", settings.opacity)).foregroundStyle(.secondary) }
                    Slider(value: $settings.width, in: 0.2...1.2) { Text("宽度") }.liquidGlassControl()
                    HStack { Text("宽度"); Spacer(); Text(String(format: "%.2f m", settings.width)).foregroundStyle(.secondary) }
                    Slider(value: $settings.heightOffset, in: 0.0...0.35) { Text("高度") }.liquidGlassControl()
                    HStack { Text("离地高度"); Spacer(); Text(String(format: "%.2f m", settings.heightOffset)).foregroundStyle(.secondary) }
                    Slider(value: $settings.renderDistance, in: 30...200, step: 10) { Text("渲染距离") }.liquidGlassControl()
                    HStack { Text("前方显示距离"); Spacer(); Text("\(Int(settings.renderDistance)) m").foregroundStyle(.secondary) }
                    Slider(value: $settings.brightness, in: 0.2...1.0) { Text("亮度") }.liquidGlassControl()
                    Toggle("禁用深度测试（提升帧率）", isOn: $settings.disableDepthTest).liquidGlassControl()
                }

                Section(header: Text("传感器与性能")) {
                    Picker("GPS精度", selection: $settings.gpsDesiredAccuracy) {
                        Text("导航级").tag(kCLLocationAccuracyBestForNavigation)
                        Text("最佳").tag(kCLLocationAccuracyBest)
                        Text("10米").tag(kCLLocationAccuracyNearestTenMeters)
                    }
                    .liquidGlassControl()
                    Picker("相机分辨率", selection: $settings.videoResolution) {
                        ForEach(ARVideoResolution.allCases, id: \.self) { resolution in
                            Text(resolution.title).tag(resolution)
                        }
                    }
                    .liquidGlassControl()
                    Toggle("省电模式（AR 30fps）", isOn: $settings.powerSavingMode).liquidGlassControl()
                }

                Section(header: Text("单位")) {
                    Toggle("公制单位", isOn: $settings.metricUnits).liquidGlassControl()
                }

                Section(header: Text("安全")) {
                    Text("请只在封闭赛道使用。手机必须固定牢靠，AR提示不能替代驾驶判断。")
                        .foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(.black)
            .tint(.white)
            .navigationTitle("设置")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
            .buttonStyle(.glass)
        }
        .background(.black)
    }
}
