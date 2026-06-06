import Foundation
import CoreLocation
import CoreMotion

@MainActor
final class LocationManager: NSObject, ObservableObject {
    @Published private(set) var fusedPose: FusedPose?
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var statusMessage = "等待传感器初始化"
    @Published var isCalibrated = false
    @Published var originCoordinate: CLLocationCoordinate2D?

    private let locationManager = CLLocationManager()
    private let motionManager = CMMotionManager()
    private var fusionTimer: Timer?
    private var latestLocation: CLLocation?
    private var latestMotion: CMDeviceMotion?
    private var kalman = SimplePositionKalmanFilter()
    private var lastStartCrossingAt = Date.distantPast

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.activityType = .automotiveNavigation
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.distanceFilter = kCLDistanceFilterNone
        authorizationStatus = locationManager.authorizationStatus
    }

    func requestPermissionsAndStart(desiredAccuracy: Double = kCLLocationAccuracyBestForNavigation) {
        locationManager.desiredAccuracy = desiredAccuracy
        if authorizationStatus == .notDetermined { locationManager.requestWhenInUseAuthorization() }
        startSensors()
    }

    func startSensors() {
        guard CLLocationManager.locationServicesEnabled() else { statusMessage = "定位服务未开启"; return }
        locationManager.startUpdatingLocation()
        locationManager.startUpdatingHeading()
        if motionManager.isDeviceMotionAvailable {
            motionManager.deviceMotionUpdateInterval = 1.0 / 100.0
            motionManager.startDeviceMotionUpdates(using: .xArbitraryCorrectedZVertical, to: .main) { [weak self] motion, _ in
                Task { @MainActor in self?.latestMotion = motion }
            }
        } else { statusMessage = "当前设备不支持DeviceMotion" }
        fusionTimer?.invalidate()
        fusionTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.produceFusedPose() }
        }
        statusMessage = "传感器运行中"
    }

    func stopSensors() {
        fusionTimer?.invalidate()
        fusionTimer = nil
        locationManager.stopUpdatingLocation()
        locationManager.stopUpdatingHeading()
        motionManager.stopDeviceMotionUpdates()
        statusMessage = "传感器已暂停"
    }

    func manualCalibrate(using track: TrackData?) {
        if let current = latestLocation?.coordinate {
            originCoordinate = current
            isCalibrated = true
            statusMessage = "已按当前位置手动校准"
        } else if let start = track?.startCoordinate {
            originCoordinate = start
            isCalibrated = true
            statusMessage = "已按赛道起点校准"
        } else { statusMessage = "没有可用于校准的位置" }
    }

    func autoCalibrateIfNeeded(track: TrackData?) {
        guard let track, let start = track.startCoordinate, let current = latestLocation?.coordinate else { return }
        let distance = GeoConverter.distanceMeters(from: current, to: start)
        let cooldownPassed = Date().timeIntervalSince(lastStartCrossingAt) > 10.0
        if distance < 5.0, cooldownPassed {
            // 经过起点线时重置AR原点和滤波状态，用每圈的已知位置抵消累计漂移。
            originCoordinate = start
            isCalibrated = true
            lastStartCrossingAt = Date()
            kalman.reset(to: latestLocation)
            statusMessage = "经过起点线，已自动修正位置"
        }
    }

    private func produceFusedPose() {
        guard let latestLocation else { return }
        kalman.update(location: latestLocation, motion: latestMotion)
        let coordinate = kalman.currentCoordinate ?? latestLocation.coordinate
        let speed = max(kalman.currentSpeed, latestLocation.speed >= 0 ? latestLocation.speed : 0)
        fusedPose = FusedPose(coordinate: coordinate, speed: speed, course: latestLocation.course, yaw: latestMotion?.attitude.yaw ?? 0, timestamp: Date(), horizontalAccuracy: latestLocation.horizontalAccuracy)
    }
}

extension LocationManager: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            authorizationStatus = manager.authorizationStatus
            switch manager.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                statusMessage = "定位权限已授权"
                startSensors()
            case .denied, .restricted: statusMessage = "定位权限被拒绝，请在系统设置中开启"
            case .notDetermined: statusMessage = "等待定位授权"
            @unknown default: statusMessage = "未知定位权限状态"
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            latestLocation = location
            if originCoordinate == nil { originCoordinate = location.coordinate }
            if location.horizontalAccuracy > 15 { statusMessage = "GPS信号较弱：±\(Int(location.horizontalAccuracy))m" }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in statusMessage = "定位失败：\(error.localizedDescription)" }
    }
}

private struct SimplePositionKalmanFilter {
    private(set) var currentCoordinate: CLLocationCoordinate2D?
    private(set) var currentSpeed: Double = 0
    private var varianceLatitude = 8.0
    private var varianceLongitude = 8.0
    private var lastUpdate = Date()

    mutating func reset(to location: CLLocation?) {
        currentCoordinate = location?.coordinate
        currentSpeed = max(location?.speed ?? 0, 0)
        varianceLatitude = 4
        varianceLongitude = 4
        lastUpdate = Date()
    }

    /// 简化版卡尔曼滤波：GPS作为观测，IMU纵向加速度作为预测项，20Hz输出平滑位置/速度。
    mutating func update(location: CLLocation, motion: CMDeviceMotion?) {
        let now = Date()
        let dt = min(max(now.timeIntervalSince(lastUpdate), 0.001), 0.2)
        lastUpdate = now
        if currentCoordinate == nil { reset(to: location); return }
        let measuredSpeed = max(location.speed, 0)
        let acceleration = motion?.userAcceleration.y ?? 0
        currentSpeed = max(0, currentSpeed + acceleration * 9.80665 * dt)
        currentSpeed = currentSpeed * 0.82 + measuredSpeed * 0.18
        let gpsVariance = max(pow(location.horizontalAccuracy, 2), 1)
        let processNoise = 0.8 + abs(acceleration) * 1.5
        varianceLatitude += processNoise
        varianceLongitude += processNoise
        let latGain = varianceLatitude / (varianceLatitude + gpsVariance)
        let lonGain = varianceLongitude / (varianceLongitude + gpsVariance)
        if var coordinate = currentCoordinate {
            coordinate.latitude += latGain * (location.coordinate.latitude - coordinate.latitude)
            coordinate.longitude += lonGain * (location.coordinate.longitude - coordinate.longitude)
            currentCoordinate = coordinate
        }
        varianceLatitude = (1 - latGain) * varianceLatitude
        varianceLongitude = (1 - lonGain) * varianceLongitude
    }
}
