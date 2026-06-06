import Foundation
import CoreLocation
import SceneKit
import UIKit

enum TrackPointColor: String, Codable, CaseIterable {
    case green, orange, red

    var uiColor: UIColor {
        switch self {
        case .green: return UIColor(red: 0.0, green: 1.0, blue: 0.25, alpha: 1.0)
        case .orange: return UIColor(red: 1.0, green: 0.55, blue: 0.0, alpha: 1.0)
        case .red: return UIColor(red: 1.0, green: 0.05, blue: 0.0, alpha: 1.0)
        }
    }

    var drivingHint: String {
        switch self {
        case .green: return "全油门"
        case .orange: return "松油"
        case .red: return "刹车"
        }
    }
}

struct TrackPoint: Codable, Identifiable, Hashable {
    var id = UUID()
    var latitude: Double
    var longitude: Double
    var speed: Double
    var color: TrackPointColor

    enum CodingKeys: String, CodingKey { case latitude, longitude, speed, color }
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

struct TrackData: Codable, Identifiable, Hashable {
    var id = UUID()
    var trackName: String
    var trackLength: Double
    var cornerCount: Int
    var points: [TrackPoint]
    var importedAt = Date()

    enum CodingKeys: String, CodingKey { case trackName, trackLength, cornerCount, points }
    var startCoordinate: CLLocationCoordinate2D? { points.first?.coordinate }
}

enum ARVideoResolution: String, Codable, CaseIterable {
    case p720
    case p1080

    var title: String {
        switch self {
        case .p720: return "720p（低发热）"
        case .p1080: return "1080p（更清晰）"
        }
    }

    var targetHeight: Int {
        switch self {
        case .p720: return 720
        case .p1080: return 1080
        }
    }
}

struct ARLineSettings: Codable, Equatable {
    var opacity: Double = 0.82
    var width: Double = 0.5
    var brightness: Double = 1.0
    var renderDistance: Double = 90
    var heightOffset: Double = 0.03
    var videoResolution: ARVideoResolution = .p720
    var powerSavingMode: Bool = false
    var disableDepthTest: Bool = true
    var metricUnits: Bool = true
    var gpsDesiredAccuracy: Double = kCLLocationAccuracyBestForNavigation
}

struct FusedPose {
    var coordinate: CLLocationCoordinate2D
    var speed: Double
    var course: Double
    var yaw: Double
    var timestamp: Date
    var horizontalAccuracy: Double
}

struct UTMCoordinate: Equatable {
    enum Hemisphere: String { case north, south }
    var easting: Double
    var northing: Double
    var zone: Int
    var hemisphere: Hemisphere
}

enum GeoConverter {
    /// WGS84经纬度转UTM平面坐标。ARKit以米为单位，因此先转UTM，再相对原点做差。
    static func wgs84ToUTM(latitude: Double, longitude: Double) -> UTMCoordinate {
        let a = 6_378_137.0
        let e2 = 0.00669438
        let k0 = 0.9996
        let lat = latitude * .pi / 180.0
        let lon = longitude * .pi / 180.0
        let zone = Int((longitude + 180.0) / 6.0) + 1
        let lon0 = (Double(zone - 1) * 6.0 - 180.0 + 3.0) * .pi / 180.0
        let ep2 = e2 / (1.0 - e2)
        let n = a / sqrt(1.0 - e2 * pow(sin(lat), 2.0))
        let t = pow(tan(lat), 2.0)
        let c = ep2 * pow(cos(lat), 2.0)
        let aa = cos(lat) * (lon - lon0)
        let m = a * ((1.0 - e2 / 4.0 - 3.0 * pow(e2, 2) / 64.0 - 5.0 * pow(e2, 3) / 256.0) * lat - (3.0 * e2 / 8.0 + 3.0 * pow(e2, 2) / 32.0 + 45.0 * pow(e2, 3) / 1024.0) * sin(2.0 * lat) + (15.0 * pow(e2, 2) / 256.0 + 45.0 * pow(e2, 3) / 1024.0) * sin(4.0 * lat) - (35.0 * pow(e2, 3) / 3072.0) * sin(6.0 * lat))
        let easting = k0 * n * (aa + (1.0 - t + c) * pow(aa, 3) / 6.0 + (5.0 - 18.0 * t + pow(t, 2) + 72.0 * c - 58.0 * ep2) * pow(aa, 5) / 120.0) + 500_000.0
        var northing = k0 * (m + n * tan(lat) * (pow(aa, 2) / 2.0 + (5.0 - t + 9.0 * c + 4.0 * pow(c, 2)) * pow(aa, 4) / 24.0 + (61.0 - 58.0 * t + pow(t, 2) + 600.0 * c - 330.0 * ep2) * pow(aa, 6) / 720.0))
        let hemisphere: UTMCoordinate.Hemisphere = latitude >= 0 ? .north : .south
        if hemisphere == .south { northing += 10_000_000.0 }
        return UTMCoordinate(easting: easting, northing: northing, zone: zone, hemisphere: hemisphere)
    }

    static func arPosition(for coordinate: CLLocationCoordinate2D, origin: CLLocationCoordinate2D, altitude: Float = -0.02) -> SCNVector3 {
        let o = wgs84ToUTM(latitude: origin.latitude, longitude: origin.longitude)
        let p = wgs84ToUTM(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return SCNVector3(Float(p.easting - o.easting), altitude, -Float(p.northing - o.northing))
    }

    static func distanceMeters(from lhs: CLLocationCoordinate2D, to rhs: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: lhs.latitude, longitude: lhs.longitude).distance(from: CLLocation(latitude: rhs.latitude, longitude: rhs.longitude))
    }
}
