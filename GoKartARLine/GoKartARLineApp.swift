import SwiftUI

@main
struct GoKartARLineApp: App {
    @StateObject private var trackDataManager = TrackDataManager()
    @StateObject private var locationManager = LocationManager()
    @AppStorage("hasAcceptedSafetyWarning") private var hasAcceptedSafetyWarning = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(trackDataManager)
                .environmentObject(locationManager)
                .alert("安全提示", isPresented: .constant(!hasAcceptedSafetyWarning)) {
                    Button("我已理解，继续使用") { hasAcceptedSafetyWarning = true }
                } message: {
                    Text("AR行车线仅作辅助参考，可能受GPS、IMU、光照和AR跟踪影响产生偏差。驾驶员必须始终专注驾驶，遵守场地规则，并将手机牢固固定在不遮挡视线的位置。")
                }
        }
    }
}
