# GoKartARLine

纯 iPhone 卡丁车 AR 动态行车线 App。项目基于 iOS 17+、SwiftUI、ARKit 6、CoreLocation、CoreMotion，零第三方库、零外部硬件依赖。

## 运行要求

- Xcode 15.4 或更新版本
- iOS 17.0 或更新版本
- 真机 iPhone；模拟器无法完整验证 ARKit、相机、GPS 和 IMU
- 在 Xcode 中设置自己的 Signing Team，并按需修改 Bundle Identifier

## 项目结构

- `GoKartARLine.xcodeproj`：Xcode 工程
- `GoKartARLine/GoKartARLineApp.swift`：App 入口与强制安全提示
- `GoKartARLine/ContentView.swift`：主界面、HUD、导入、校准、截图、赛道列表
- `GoKartARLine/ARViewContainer.swift`：ARSCNView 容器、低延迟 AR 配置、3D 行车线渲染
- `GoKartARLine/LocationManager.swift`：GPS + IMU 融合、20Hz 简化卡尔曼滤波、自动/手动校准
- `GoKartARLine/TrackDataManager.swift`：JSON/GPX 导入、本地存储、删除、重命名
- `GoKartARLine/TrackPoint.swift`：数据模型、颜色提示、WGS84 到 UTM 转换
- `GoKartARLine/SettingsView.swift`：样式、传感器、省电、单位设置
- `SampleTrack.json`：包含 120 个轨迹点的示例赛道数据

## 如何运行

1. 用 Xcode 打开 `GoKartARLine.xcodeproj`。
2. 选择 `GoKartARLine` target，设置 Signing Team。
3. 连接 iPhone 真机，选择真机作为运行目标。
4. 点击 Run。首次启动会请求相机、定位、运动传感器和相册写入权限。

## 如何导入赛道数据

App 支持从 AirDrop、文件 App 或主界面的“导入”按钮选择 `.json` / `.gpx` 文件。

JSON 格式：

```json
{
  "trackName": "XX卡丁车场",
  "trackLength": 1200,
  "cornerCount": 8,
  "points": [
    {
      "latitude": 31.234567,
      "longitude": 121.345678,
      "speed": 65,
      "color": "green"
    }
  ]
}
```

要求：

- `points` 至少 100 个点
- `color` 只能是 `green`、`orange`、`red`
- 经纬度必须是 WGS84
- GPX 导入会转换为内部 JSON 数据；默认速度为 50，颜色为绿色

## 校准位置

- 自动起点校准：第一次经过赛道第一个轨迹点附近 5 米内时，App 自动完成全局位置校准。
- 每圈自动修正：之后每次经过起点线附近，都会重置滤波误差和 AR 原点。
- 手动校准：点击底部“校准”，优先用当前 GPS 位置；无 GPS 时使用赛道起点。

## 最佳使用方式

- 默认横屏使用，适合固定在卡丁车上。
- 手机应牢固固定，不能遮挡驾驶视线。
- 尽量在室外开阔环境使用，GPS 精度建议优于 ±5 米。
- 第一次上赛道建议低速经过起点，让自动校准稳定后再加速。
- 可在“设置”中实时调整行车线透明度、宽度、亮度和 30fps 省电模式。

## 安全说明

AR 行车线只作辅助参考，不能替代驾驶员判断。GPS 漂移、IMU 噪声、AR 跟踪失败、赛道数据错误都可能造成行车线偏移。请只在封闭卡丁车场使用，并遵守场地安全规则。
