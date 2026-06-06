import Foundation
import UIKit
import CoreLocation
import Security

struct AITrackImagePoint: Codable, Hashable {
    var x: Double
    var y: Double
    var speed: Double
    var color: TrackPointColor
    var remark: String
}

struct AITrackResponse: Codable, Hashable {
    var trackName: String
    var trackLength: Double
    var cornerCount: Int
    var trackDescription: String?
    var drivingTips: String?
    var points: [AITrackImagePoint]
}

struct AITrackGenerationRequest {
    var image: UIImage
    var finishPoint: CGPoint
    var imageSize: CGSize
    var originCoordinate: CLLocationCoordinate2D
}

struct AIMapTrackPoint: Codable, Hashable {
    var latitude: Double
    var longitude: Double
    var speed: Double
    var color: TrackPointColor
    var remark: String?
}

struct AIMapTrackResponse: Codable, Hashable {
    var trackName: String
    var trackLength: Double
    var cornerCount: Int
    var points: [AIMapTrackPoint]
}

enum AITrackGenerationError: LocalizedError {
    case missingAPIKey
    case invalidImage
    case invalidURL
    case invalidResponse
    case noJSON
    case server(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "请先输入AI接口Key"
        case .invalidImage: return "图片处理失败"
        case .invalidURL: return "AI接口URL无效"
        case .invalidResponse: return "AI接口响应无效"
        case .noJSON: return "AI没有返回合法JSON"
        case .server(let message): return message
        }
    }
}

final class AITrackGenerationService {
    static let shared = AITrackGenerationService()

    static let defaultBaseURL = "https://api.tutujin.com/v1"
    static let defaultModel = "claude-3-5-sonnet-20240620"
    private let apiKeyStoreKey = "ai.track.generator.api.key"
    private let modelStoreKey = "ai.track.generator.model"
    private let baseURLStoreKey = "ai.track.generator.base.url"
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    var baseURLString: String {
        get {
            let saved = UserDefaults.standard.string(forKey: baseURLStoreKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return saved?.isEmpty == false ? saved! : Self.defaultBaseURL
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(trimmed.isEmpty ? Self.defaultBaseURL : trimmed, forKey: baseURLStoreKey)
        }
    }

    var baseURL: URL? {
        URL(string: baseURLString.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var model: String {
        get {
            let saved = UserDefaults.standard.string(forKey: modelStoreKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return saved?.isEmpty == false ? saved! : Self.defaultModel
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            UserDefaults.standard.set(trimmed.isEmpty ? Self.defaultModel : trimmed, forKey: modelStoreKey)
        }
    }

    var apiKey: String {
        get { KeychainStore.load(key: apiKeyStoreKey) ?? "" }
        set {
            if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                KeychainStore.delete(key: apiKeyStoreKey)
            } else {
                KeychainStore.save(newValue.trimmingCharacters(in: .whitespacesAndNewlines), key: apiKeyStoreKey)
            }
        }
    }

    func generateTrack(request: AITrackGenerationRequest) async throws -> TrackData {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AITrackGenerationError.missingAPIKey }
        let uploadedImage = request.image.resizedForAI(maxDimension: 1170)
        let scaleX = uploadedImage.size.width / max(request.image.size.width, 1)
        let scaleY = uploadedImage.size.height / max(request.image.size.height, 1)
        let uploadedFinishPoint = CGPoint(x: request.finishPoint.x * scaleX, y: request.finishPoint.y * scaleY)
        guard let jpegData = uploadedImage.jpegData(compressionQuality: 0.82) else {
            throw AITrackGenerationError.invalidImage
        }

        guard let baseURL else { throw AITrackGenerationError.invalidURL }
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = 180

        let imageBase64 = jpegData.base64EncodedString()
        let endpoint = "终点像素坐标：x=\(Int(uploadedFinishPoint.x))，y=\(Int(uploadedFinishPoint.y))。图片尺寸：width=\(Int(uploadedImage.size.width))，height=\(Int(uploadedImage.size.height))。请把该点作为起终点附近参考。"
        let body = ChatCompletionRequest(
            model: model,
            messages: [
                ChatMessage(role: "system", content: [.text(Self.systemPrompt)]),
                ChatMessage(role: "user", content: [.text(endpoint), .imageURL("data:image/jpeg;base64,\(imageBase64)")])
            ],
            temperature: 0.1,
            max_tokens: 12000
        )
        urlRequest.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw AITrackGenerationError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw AITrackGenerationError.server(message)
        }
        let completion = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        guard let content = completion.choices.first?.message.content else { throw AITrackGenerationError.noJSON }
        let jsonText = Self.extractJSONObject(from: content)
        guard let jsonData = jsonText.data(using: .utf8) else { throw AITrackGenerationError.noJSON }
        let aiTrack = try JSONDecoder().decode(AITrackResponse.self, from: jsonData)
        return Self.convertToTrackData(aiTrack, origin: request.originCoordinate)
    }


    func generateBrakeZones(from coordinates: [CLLocationCoordinate2D], trackName: String) async throws -> TrackData {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AITrackGenerationError.missingAPIKey }
        guard coordinates.count >= 4 else { throw AITrackGenerationError.noJSON }
        guard let baseURL else { throw AITrackGenerationError.invalidURL }

        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = 180

        let coordinateText = coordinates.enumerated().map { index, coordinate in
            "{\"index\":\(index),\"latitude\":\(String(format: "%.8f", coordinate.latitude)),\"longitude\":\(String(format: "%.8f", coordinate.longitude))}"
        }.joined(separator: ",")
        let length = zip(coordinates, coordinates.dropFirst()).reduce(0.0) { partial, pair in
            partial + GeoConverter.distanceMeters(from: pair.0, to: pair.1)
        }
        let userPrompt = """
        用户在高德/地图实景底图上手绘了一条首尾相接的卡丁车赛道中心线。请基于这些WGS84经纬度轨迹点生成完整赛道行车线和刹车区。
        赛道名称：\(trackName)
        手绘轨迹总长约：\(Int(length))米
        手绘轨迹点JSON数组：[\(coordinateText)]
        """
        let body = ChatCompletionRequest(
            model: model,
            messages: [
                ChatMessage(role: "system", content: [.text(Self.mapBrakeZonePrompt)]),
                ChatMessage(role: "user", content: [.text(userPrompt)])
            ],
            temperature: 0.1,
            max_tokens: 12000
        )
        urlRequest.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw AITrackGenerationError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw AITrackGenerationError.server(message)
        }
        let completion = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        guard let content = completion.choices.first?.message.content else { throw AITrackGenerationError.noJSON }
        let jsonText = Self.extractJSONObject(from: content)
        guard let jsonData = jsonText.data(using: .utf8) else { throw AITrackGenerationError.noJSON }
        let aiTrack = try JSONDecoder().decode(AIMapTrackResponse.self, from: jsonData)
        let points = aiTrack.points.map {
            TrackPoint(latitude: $0.latitude, longitude: $0.longitude, speed: $0.speed, color: $0.color)
        }
        return TrackData(trackName: aiTrack.trackName, trackLength: aiTrack.trackLength, cornerCount: aiTrack.cornerCount, points: points, importedAt: Date())
    }

    static func convertToTrackData(_ aiTrack: AITrackResponse, origin: CLLocationCoordinate2D, currentImagePoint: CGPoint? = nil, headingDegrees: Double = 0) -> TrackData {
        let pixelLength = zip(aiTrack.points, aiTrack.points.dropFirst()).reduce(0.0) { partial, pair in
            let dx = pair.1.x - pair.0.x
            let dy = pair.1.y - pair.0.y
            return partial + sqrt(dx * dx + dy * dy)
        }
        let metersPerPixel = pixelLength > 1 ? aiTrack.trackLength / pixelLength : 0.5
        let start = aiTrack.points.first ?? AITrackImagePoint(x: 0, y: 0, speed: 0, color: .green, remark: "起点")
        let anchor = currentImagePoint.map { AITrackImagePoint(x: $0.x, y: $0.y, speed: 0, color: .green, remark: "当前位置") } ?? start
        let heading = headingDegrees * .pi / 180.0
        let latitudeMeters = 111_320.0
        let longitudeMeters = max(cos(origin.latitude * .pi / 180.0) * 111_320.0, 1.0)
        let points = aiTrack.points.map { point in
            let imageEast = (point.x - anchor.x) * metersPerPixel
            let imageNorth = -(point.y - anchor.y) * metersPerPixel
            let east = imageEast * cos(heading) - imageNorth * sin(heading)
            let north = imageEast * sin(heading) + imageNorth * cos(heading)
            return TrackPoint(
                latitude: origin.latitude + north / latitudeMeters,
                longitude: origin.longitude + east / longitudeMeters,
                speed: point.speed,
                color: point.color
            )
        }
        return TrackData(trackName: aiTrack.trackName, trackLength: aiTrack.trackLength, cornerCount: aiTrack.cornerCount, points: points, importedAt: Date())
    }

    private static func extractJSONObject(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") { return trimmed }
        guard let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}") else { return trimmed }
        return String(trimmed[start...end])
    }

    private static let systemPrompt = """
你是专业卡丁车赛道分析AI，必须一次性、完整地完成所有任务，绝对不允许分多次输出，绝对不允许追问任何问题，绝对不允许输出任何除JSON以外的内容。

## 【必须按顺序执行的强制步骤】
1.  【路径识别】：仔细观察整张图，识别完整的闭环赛道。黑色沥青=可行驶区域，绿色草地/花坛/隔离带/护栏=绝对不可通行的障碍物。
2.  【自我校验1】：在思维链中画出完整的行驶路径，逐段检查是否有任何穿越障碍物的地方，如有立即修正。
3.  【弯道识别】：数出所有弯道的数量，区分左弯/右弯/发卡弯/S弯，为每个弯道标记刹车点→入弯点→弯心→出弯点。
4.  【行车线生成】：严格按照“外-内-外”经典赛车走线原则生成最优行车线。直道走中线，入弯前向外靠，弯心贴内，出弯向外展开。
5.  【速度规划】：基于卡丁车通用参数（最高时速80km/h，刹车减速度-0.8g，横向抓地力1.2g）计算每个点的建议车速。
6.  【颜色标记】：green=全油门区，orange=松油区，red=重刹区，颜色渐变自然，不要突然切换。
7.  【点间距要求】：轨迹点不要过密，相邻点对应真实距离约0.5米；直道可略稀疏，弯心和刹车区必须足够平滑，整体应像 F1 辅助行车线一样连续、贴地、无跳跃。
8.  【自我校验2】：检查所有轨迹点是否都在黑色沥青路面上；检查行车线是否平滑连续，没有突变或跳跃；检查点间距是否接近0.5米且足够平滑；检查JSON格式是否完全正确，没有任何语法错误。

## 【输出要求】
只输出纯JSON，不要任何其他文字、解释、道歉、说明或思维链，直接输出：
{
  "trackName": "赛道名称",
  "trackLength": 赛道长度米,
  "cornerCount": 弯道数量,
  "trackDescription": "赛道特点描述",
  "drivingTips": "整体走线要点和关键弯道注意事项",
  "points": [
    {
      "x": 相对于图片左上角的水平像素坐标,
      "y": 相对于图片左上角的垂直像素坐标,
      "speed": 建议车速km/h,
      "color": "green/orange/red",
      "remark": "刹车点/入弯点/弯心/出弯点/普通点"
    }
  ]
}

## 【绝对禁止】
- 禁止说“我无法分析”、“我需要更多信息”等任何拒绝的话
- 禁止输出除了JSON以外的任何内容
- 禁止分多次输出
- 禁止生成穿越草地或障碍物的行车线
- 禁止轨迹点过密；相邻点应尽量对应约0.5米真实距离
"""
    private static let mapBrakeZonePrompt = """
你是专业卡丁车赛道工程师。用户已经在地图实景底图上画出一条首尾相接的赛道中心线，你必须基于经纬度轨迹生成可直接导入App的JSON。

## 任务
1. 保留赛道整体形状，必要时把手绘稀疏点重采样为约0.5米间距的平滑闭环轨迹。
2. 识别直道、弯道、发卡弯和S弯，估算弯道数量。
3. 为每个输出点生成建议车速 speed，单位 km/h。
4. 为每个输出点生成 color：green=全油门，orange=松油/入弯准备，red=刹车区。
5. 刹车区必须出现在弯前，不能只把弯心标红；直道中后段通常为green，入弯前逐渐orange/red，出弯恢复green。
6. 输出points必须是WGS84经纬度，不要输出像素坐标。

## 输出要求
只输出纯JSON，不要解释，不要Markdown：
{
  "trackName": "赛道名称",
  "trackLength": 赛道长度米,
  "cornerCount": 弯道数量,
  "points": [
    {
      "latitude": 31.000000,
      "longitude": 121.000000,
      "speed": 55,
      "color": "green/orange/red",
      "remark": "普通点/刹车点/入弯点/弯心/出弯点"
    }
  ]
}

## 绝对禁止
- 禁止输出JSON以外的文字
- 禁止返回非闭环轨迹
- 禁止输出少于100个轨迹点
- 禁止使用除green、orange、red以外的颜色
"""
}

private struct ChatCompletionRequest: Encodable {
    var model: String
    var messages: [ChatMessage]
    var temperature: Double
    var max_tokens: Int
}

private struct ChatMessage: Encodable {
    var role: String
    var content: [ChatContent]
}

private enum ChatContent: Encodable {
    case text(String)
    case imageURL(String)

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .imageURL(let url):
            try container.encode("image_url", forKey: .type)
            try container.encode(ImageURL(url: url), forKey: .image_url)
        }
    }

    private enum CodingKeys: String, CodingKey { case type, text, image_url }
    private struct ImageURL: Encodable { var url: String }
}

private struct ChatCompletionResponse: Decodable {
    var choices: [Choice]
    struct Choice: Decodable { var message: Message }
    struct Message: Decodable { var content: String }
}

enum KeychainStore {
    static func save(_ value: String, key: String) {
        let data = Data(value.utf8)
        delete(key: key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}

private extension UIImage {
    func resizedForAI(maxDimension: CGFloat) -> UIImage {
        let maximum = max(size.width, size.height)
        guard maximum > maxDimension else { return self }
        let scale = maxDimension / maximum
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: target)
        return renderer.image { _ in draw(in: CGRect(origin: .zero, size: target)) }
    }
}
