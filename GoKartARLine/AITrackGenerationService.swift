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

enum AITrackGenerationError: LocalizedError {
    case missingAPIKey
    case invalidImage
    case invalidURL
    case invalidResponse
    case noJSON
    case tooFewPoints
    case server(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "请先输入AI接口Key"
        case .invalidImage: return "图片处理失败"
        case .invalidURL: return "AI接口URL无效"
        case .invalidResponse: return "AI接口响应无效"
        case .noJSON: return "AI没有返回合法JSON"
        case .tooFewPoints: return "AI生成的轨迹点少于200个"
        case .server(let message): return message
        }
    }
}

final class AITrackGenerationService {
    static let shared = AITrackGenerationService()

    let baseURL = URL(string: "https://api.tutujin.com/v1")!
    static let defaultModel = "claude-3-5-sonnet-20240620"
    private let apiKeyStoreKey = "ai.track.generator.api.key"
    private let modelStoreKey = "ai.track.generator.model"
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
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
        guard aiTrack.points.count >= 200 else { throw AITrackGenerationError.tooFewPoints }
        return Self.convertToTrackData(aiTrack, origin: request.originCoordinate)
    }

    private static func convertToTrackData(_ aiTrack: AITrackResponse, origin: CLLocationCoordinate2D) -> TrackData {
        let pixelLength = zip(aiTrack.points, aiTrack.points.dropFirst()).reduce(0.0) { partial, pair in
            let dx = pair.1.x - pair.0.x
            let dy = pair.1.y - pair.0.y
            return partial + sqrt(dx * dx + dy * dy)
        }
        let metersPerPixel = pixelLength > 1 ? aiTrack.trackLength / pixelLength : 0.5
        let start = aiTrack.points.first ?? AITrackImagePoint(x: 0, y: 0, speed: 0, color: .green, remark: "起点")
        let latitudeMeters = 111_320.0
        let longitudeMeters = max(cos(origin.latitude * .pi / 180.0) * 111_320.0, 1.0)
        let points = aiTrack.points.map { point in
            let east = (point.x - start.x) * metersPerPixel
            let north = -(point.y - start.y) * metersPerPixel
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
7.  【自我校验2】：检查所有轨迹点是否都在黑色沥青路面上；检查行车线是否平滑连续，没有突变或跳跃；检查轨迹点数量是否≥200个；检查JSON格式是否完全正确，没有任何语法错误。

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
- 禁止轨迹点数量少于200个
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


