# GoKartARLine

详细中文使用教程：Docs/USER_GUIDE_zh-CN.md。

纯 iPhone / Android 卡丁车 AR 动态行车线 App。iOS 最低版本为 iOS 16.0，使用 SwiftUI、ARKit、CoreLocation、CoreMotion；Android 使用原生 Java 单 Activity 实现。

## 运行要求

- Xcode 15.4 或更新版本
- iOS 16.0 或更新版本
- 真机 iPhone；模拟器无法完整验证 ARKit、相机、GPS 和 IMU
- 在 Xcode 中设置自己的 Signing Team，并按需修改 Bundle Identifier

## 项目结构

- `GoKartARLine.xcodeproj`：Xcode 工程
- `GoKartARLine/GoKartARLineApp.swift`：App 入口与强制安全提示
- `GoKartARLine/ContentView.swift`：主界面、HUD、导入、校准、截图、赛道列表
- `GoKartARLine/ARViewContainer.swift`：ARSCNView 容器、低延迟 AR 配置、3D 行车线渲染
- `GoKartARLine/LocationManager.swift`：GPS + IMU 融合、20Hz 简化卡尔曼滤波、智能吸附校准
- `GoKartARLine/TrackDataManager.swift`：JSON/GPX 导入、本地存储、删除、重命名
- `GoKartARLine/TrackPoint.swift`：数据模型、颜色提示、WGS84 到 UTM 转换
- `GoKartARLine/SettingsView.swift`：样式、传感器、省电、单位设置
- `GoKartARLine/TrackMapCalibrationView.swift`：旧版地图位置与方向校准视图（保留为备用）
- `GoKartARLine/OnlineSyncManager.swift`：注册登录、在线地图分享、下载、排行榜、圈速上传
- `server/`：16781 端口在线服务端，HTTP API/admin 与 UDP 遥测同端口
- `SampleTrack.json`：包含 120 个轨迹点的示例赛道数据

## 如何运行

1. 用 Xcode 打开 `GoKartARLine.xcodeproj`。
2. 选择 `GoKartARLine` target，设置 Signing Team。
3. 连接 iPhone 真机，选择真机作为运行目标。
4. 点击 Run。首次启动会请求相机、定位、运动传感器和相册写入权限。

## 如何导入赛道数据

App 支持从 AirDrop、文件 App 或主界面的“导入”按钮选择 `.json` / `.gpx` 文件，也可以在赛道列表中使用“图片描线”从俯视图手动描出中心线生成赛道。

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
- 图片描线不再依赖 AI 自动猜图：选择照片后沿赛道中心线描一圈，输入大致长度；如果照片比例不准，填写赛道整体宽度和高度，App 会按外接长宽自动修正比例并本地重采样。

## 在线功能

底部点击 `在线` 可使用：

- 注册/登录：用户名、密码、邮箱、验证码。
- 地图分享：上传当前赛道，服务端识别闭合度、长度、范围、弯道特征；符合真卡丁车场特征才进入分享页。
- 地图下载：从分享页下载其他用户地图并导入本地使用。
- 排行榜：下载的共享赛道每圈自动记录圈速、GPS 精度和采样数据，服务端展示前十。
- 遥测建议：每圈同步上传加速度与行车线偏离采样，服务端估算油门、刹车、平顺性和偏离程度，并返回提升建议。
- 自动优化：跑完一圈后上传 GPS 采样，服务端按多圈数据微调赛道轨迹，提高共享赛道精度。

服务端默认地址：`http://cheap-host1.cheapyun.com:16781`。后端配置页同端口：`/admin`。

## 校准位置

- 自动起点校准：第一次经过赛道第一个轨迹点附近 5 米内时，App 自动完成全局位置校准。
- 每圈自动修正：之后每次经过起点线附近，都会重置滤波误差和 AR 原点。
- 选择赛道校准：点击底部“赛道”并选择某条赛道后，会直接执行智能校准并返回主界面。
- 智能校准：点击底部“智能校准”或在赛道列表选择赛道后，App 会自动吸附到最近赛道线段，并用当前行驶/罗盘方向判断正反方向；Android 会保存该校准状态。
- 室内无 GPS 时，加速度计/陀螺仪只能做短时间姿态和平滑辅助，不能提供稳定绝对位置；AR 行车线仍需要手动起点/朝向锚定，或接入 UWB、视觉定位等外部定位源。

## 最佳使用方式

- 默认横屏使用，适合固定在卡丁车上。
- 手机应牢固固定，不能遮挡驾驶视线。
- 尽量在室外开阔环境使用，GPS 精度建议优于 ±5 米。
- 第一次上赛道建议先在“赛道”列表选择赛道触发智能校准，再低速经过起点让自动校准进一步修正。
- 可在“设置”中实时调整行车线透明度、宽度、亮度和 30fps 省电模式。

## 安全说明

AR 行车线只作辅助参考，不能替代驾驶员判断。GPS 漂移、IMU 噪声、AR 跟踪失败、赛道数据错误都可能造成行车线偏移。请只在封闭卡丁车场使用，并遵守场地安全规则。

## GitHub Actions 未签名 IPA 构建

仓库已包含 `.github/workflows/build-unsigned-ipa.yml`，会在以下情况使用 GitHub macOS runner 构建：

- 推送到 `main`
- 手动点击 Actions 页面中的 `Build Unsigned IPA` → `Run workflow`

构建产物会上传为 Actions artifact：`GoKartARLine-unsigned-ipa`，内部文件为 `GoKartARLine-unsigned.ipa`。

注意：该 IPA 使用 `CODE_SIGNING_ALLOWED=NO` 构建，未签名，不能直接安装到普通 iPhone。它适合做编译验证、代码审查和后续再签名流程。真机安装仍需要 Apple Developer 签名、描述文件或其他合法签名方式。
