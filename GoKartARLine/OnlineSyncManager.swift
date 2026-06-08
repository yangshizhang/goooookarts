import Foundation
import SwiftUI
import CoreLocation

struct OnlineUser: Codable, Hashable {
    var id: String
    var username: String
    var email: String
    var createdAt: String
}

struct OnlineTrackSummary: Codable, Identifiable, Hashable {
    var id: String
    var trackName: String
    var trackLength: Double
    var cornerCount: Int
    var pointCount: Int
    var createdAt: String
    var updatedAt: String?
    var authorName: String
    var downloadCount: Int
    var lapCount: Int
    var thumbnailURL: String?
}

struct OnlineLeaderboardEntry: Codable, Identifiable, Hashable {
    var rank: Int
    var username: String
    var lapTimeMs: Int
    var speedKph: Double
    var gpsAccuracy: Double
    var throttleScore: Int?
    var brakeScore: Int?
    var lineDeviationAvg: Double?
    var lineDeviationMax: Double?
    var smoothnessScore: Int?
    var suggestions: [String]?
    var analysis: OnlineLapAnalysis?
    var createdAt: String

    var id: String { "\(rank)-\(username)-\(lapTimeMs)" }
}

struct OnlineLapAnalysis: Codable, Hashable {
    var sampleCount: Int
    var throttleScore: Int
    var throttleAvg: Double
    var throttleMax: Double
    var brakeScore: Int
    var brakeAvg: Double
    var brakeMax: Double
    var lateralAvg: Double
    var lineDeviationAvg: Double
    var lineDeviationMax: Double
    var smoothnessScore: Int
    var suggestions: [String]
}

@MainActor
final class OnlineSyncManager: ObservableObject {
    @Published var baseURLString: String
    @Published private(set) var user: OnlineUser?
    @Published private(set) var sharedTracks: [OnlineTrackSummary] = []
    @Published private(set) var leaderboard: [OnlineLeaderboardEntry] = []
    @Published var message: String?
    @Published var isBusy = false

    private let baseURLKey = "online.baseURL"
    private let tokenKey = "online.authToken"
    private var token: String?
    private var lapState = LapState()

    init() {
        let defaults = UserDefaults.standard
        baseURLString = defaults.string(forKey: baseURLKey) ?? "http://cheap-host1.cheapyun.com:16781"
        token = defaults.string(forKey: tokenKey)
    }

    var isLoggedIn: Bool { user != nil && token != nil }

    func saveBaseURL() {
        baseURLString = normalizedBaseURL
        UserDefaults.standard.set(baseURLString, forKey: baseURLKey)
        message = "服务器地址已保存"
    }

    func requestCode(email: String) async {
        await run {
            let response: CodeResponse = try await request("/api/auth/request-code", method: "POST", body: CodeRequest(email: email), requiresAuth: false)
            message = response.message ?? (response.emailSent ? "验证码已发送" : "验证码已生成，请检查后端邮件配置")
        }
    }

    func register(username: String, password: String, email: String, code: String) async {
        await run {
            let response: AuthResponse = try await request("/api/auth/register", method: "POST", body: RegisterRequest(username: username, password: password, email: email, code: code), requiresAuth: false)
            applyAuth(response)
            message = "注册并登录成功"
            await fetchSharedTracks()
        }
    }

    func login(login: String, password: String) async {
        await run {
            let response: AuthResponse = try await request("/api/auth/login", method: "POST", body: LoginRequest(login: login, password: password), requiresAuth: false)
            applyAuth(response)
            message = "登录成功"
            await fetchSharedTracks()
        }
    }

    func logout() {
        token = nil
        user = nil
        leaderboard = []
        UserDefaults.standard.removeObject(forKey: tokenKey)
        message = "已退出登录"
    }

    func fetchMeIfPossible() async {
        guard token != nil else { return }
        do {
            let response: MeResponse = try await request("/api/me", requiresAuth: true)
            user = response.user
        } catch {
            logout()
        }
    }

    func fetchSharedTracks() async {
        await run {
            let response: TracksResponse = try await request("/api/tracks", requiresAuth: false)
            sharedTracks = response.tracks
        }
    }

    func upload(track: TrackData, trackDataManager: TrackDataManager) async {
        await run {
            let payload = TrackUploadRequest(track: track)
            let response: TrackUploadResponse = try await request("/api/tracks", method: "POST", body: payload, requiresAuth: true)
            trackDataManager.setRemoteID(for: track.id, remoteID: response.remoteID)
            message = "已分享：\(response.track.trackName)"
            await fetchSharedTracks()
        }
    }

    func download(_ summary: OnlineTrackSummary, into manager: TrackDataManager) async {
        await run {
            let response: TrackDownloadResponse = try await request("/api/tracks/\(summary.id)/download", requiresAuth: false)
            let downloaded = response.track.asTrackData()
            manager.addGeneratedTrack(downloaded)
            message = "已下载并导入：\(downloaded.trackName)"
        }
    }

    func fetchLeaderboard(trackID: String) async {
        await run {
            let response: LeaderboardResponse = try await request("/api/tracks/\(trackID)/leaderboard", requiresAuth: false)
            leaderboard = response.leaderboard
        }
    }

    func observe(pose: FusedPose, track: TrackData?) {
        guard isLoggedIn, let track, let remoteID = track.remoteID, let start = track.startCoordinate else { return }
        let distanceToStart = GeoConverter.distanceMeters(from: pose.coordinate, to: start)
        let isNearStart = distanceToStart < 8
        if lapState.trackID != remoteID { lapState = LapState(trackID: remoteID) }
        lapState.append(pose: pose, track: track)
        defer { lapState.wasNearStart = isNearStart }
        guard isNearStart, !lapState.wasNearStart else { return }
        if let startedAt = lapState.startedAt {
            let lapTime = Date().timeIntervalSince(startedAt)
            guard lapTime > 15, lapState.samples.count >= 20 else {
                lapState.restart(at: Date(), firstPose: pose, track: track)
                return
            }
            let samples = lapState.samples
            lapState.restart(at: Date(), firstPose: pose, track: track)
            Task { await submitLap(trackID: remoteID, lapTimeMs: Int(lapTime * 1000), pose: pose, samples: samples) }
        } else {
            lapState.restart(at: Date(), firstPose: pose, track: track)
        }
    }

    private func submitLap(trackID: String, lapTimeMs: Int, pose: FusedPose, samples: [LapSample]) async {
        do {
            let requestBody = LapUploadRequest(lapTimeMs: lapTimeMs, speedKph: pose.speed * 3.6, gpsAccuracy: pose.horizontalAccuracy, samples: samples)
            let response: LapUploadResponse = try await request("/api/tracks/\(trackID)/laps", method: "POST", body: requestBody, requiresAuth: true)
            if let analysis = response.analysis {
                let suggestion = analysis.suggestions.first ?? "暂无建议"
                message = "圈速已上传：\(formatLapTime(lapTimeMs))\n油门 \(analysis.throttleScore)% · 刹车 \(analysis.brakeScore)% · 偏离 \(String(format: "%.1f", analysis.lineDeviationAvg))m\n\(suggestion)"
            } else {
                message = "圈速已上传：\(formatLapTime(lapTimeMs))"
            }
        } catch {
            message = "圈速上传失败：\(error.localizedDescription)"
        }
    }

    private func run(_ operation: () async throws -> Void) async {
        isBusy = true
        defer { isBusy = false }
        do { try await operation() }
        catch { message = error.localizedDescription }
    }

    private func applyAuth(_ response: AuthResponse) {
        token = response.token
        user = response.user
        UserDefaults.standard.set(response.token, forKey: tokenKey)
    }

    private var normalizedBaseURL: String {
        var value = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        return value.isEmpty ? "http://cheap-host1.cheapyun.com:16781" : value
    }

    private func request<Response: Decodable>(_ path: String, requiresAuth: Bool) async throws -> Response {
        try await request(path, method: "GET", body: EmptyBody(), requiresAuth: requiresAuth)
    }

    private func request<Response: Decodable, Body: Encodable>(_ path: String, method: String, body: Body, requiresAuth: Bool) async throws -> Response {
        guard let url = URL(string: normalizedBaseURL + path) else { throw OnlineError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if method != "GET" { request.httpBody = try JSONEncoder().encode(body) }
        if requiresAuth {
            guard let token else { throw OnlineError.notLoggedIn }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OnlineError.invalidResponse }
        if !(200...299).contains(http.statusCode) {
            let envelope = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            throw OnlineError.server(envelope?.error ?? "服务器错误 \(http.statusCode)")
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func formatLapTime(_ milliseconds: Int) -> String {
        let minutes = milliseconds / 60000
        let seconds = (milliseconds % 60000) / 1000
        let millis = milliseconds % 1000
        return String(format: "%d:%02d.%03d", minutes, seconds, millis)
    }
}

struct OnlineCenterView: View {
    @EnvironmentObject private var online: OnlineSyncManager
    @EnvironmentObject private var trackDataManager: TrackDataManager
    @Environment(\.dismiss) private var dismiss
    @State private var loginName = ""
    @State private var loginPassword = ""
    @State private var showingRegister = false
    @State private var selectedLeaderboardTrack: OnlineTrackSummary?

    var body: some View {
        NavigationStack {
            Form {
                if online.isLoggedIn {
                    accountSection
                    uploadSection
                    shareSection
                } else {
                    loginSection
                }
            }
            .scrollContentBackground(.hidden)
            .background(.black)
            .tint(.white)
            .navigationTitle("在线")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("刷新") { Task { await online.fetchSharedTracks() } }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .buttonStyle(.liquidGlass)
            .task {
                await online.fetchMeIfPossible()
                await online.fetchSharedTracks()
            }
            .alert("在线", isPresented: Binding(get: { online.message != nil }, set: { if !$0 { online.message = nil } })) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text(online.message ?? "")
            }
            .sheet(item: $selectedLeaderboardTrack) { track in
                LeaderboardSheet(track: track)
                    .environmentObject(online)
            }
            .sheet(isPresented: $showingRegister) {
                OnlineRegisterView()
                    .environmentObject(online)
            }
        }
        .background(.black)
    }

    private var loginSection: some View {
        Section(header: Text("登录")) {
            Text("使用用户名或邮箱登录。没有账号时进入注册页填写邮箱验证码。")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("用户名或邮箱", text: $loginName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("密码", text: $loginPassword)
            HStack {
                Button("登录") { Task { await online.login(login: loginName, password: loginPassword) } }
                Button("注册账号") { showingRegister = true }
            }
            if online.isBusy { ProgressView("处理中") }
        }
    }

    private var accountSection: some View {
        Section(header: Text("账号")) {
            Text(online.user.map { "\($0.username) · \($0.email)" } ?? "已登录")
            Button("退出登录", role: .destructive) { online.logout() }
        }
    }

    private var uploadSection: some View {
        Section(header: Text("地图分享")) {
            if let selected = trackDataManager.selectedTrack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(selected.trackName).font(.headline)
                    Text("\(Int(selected.trackLength))m · \(selected.cornerCount)弯 · \(selected.points.count)点")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button(selected.remoteID == nil ? "上传当前赛道" : "重新上传当前赛道") {
                    Task { await online.upload(track: selected, trackDataManager: trackDataManager) }
                }
            } else {
                Text("请先导入或生成一条赛道")
                    .foregroundStyle(.secondary)
            }
            Text("服务器会识别闭合度、长度、地图范围和弯道特征；只有符合真卡丁车场特征的地图会进入分享页。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var shareSection: some View {
        Section(header: Text("分享页")) {
            if online.sharedTracks.isEmpty {
                Text("暂无可下载地图")
                    .foregroundStyle(.secondary)
            }
            ForEach(online.sharedTracks) { track in
                VStack(alignment: .leading, spacing: 8) {
                    Text(track.trackName).font(.headline)
                    Text("\(Int(track.trackLength))m · \(track.cornerCount)弯 · \(track.pointCount)点 · \(track.authorName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("下载导入") { Task { await online.download(track, into: trackDataManager) } }
                        Button("排行榜") {
                            selectedLeaderboardTrack = track
                            Task { await online.fetchLeaderboard(trackID: track.id) }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

private struct OnlineRegisterView: View {
    @EnvironmentObject private var online: OnlineSyncManager
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: RegisterField?
    @State private var username = ""
    @State private var password = ""
    @State private var email = ""
    @State private var code = ""

    private enum RegisterField {
        case username, email, password, code
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("注册账号")) {
                    Text("像网站注册一样填写用户名、邮箱、密码，再通过邮件验证码完成注册。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("用户名", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .username)
                    TextField("邮箱", text: $email)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.emailAddress)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .email)
                    SecureField("密码", text: $password)
                        .focused($focusedField, equals: .password)
                    HStack {
                        TextField("邮箱验证码", text: $code)
                            .keyboardType(.numberPad)
                            .focused($focusedField, equals: .code)
                        Button("获取验证码") { Task { await online.requestCode(email: email) } }
                    }
                    Button("完成注册") {
                        focusedField = nil
                        Task {
                            await online.register(username: username, password: password, email: email, code: code)
                            if online.isLoggedIn { dismiss() }
                        }
                    }
                    if online.isBusy { ProgressView("处理中") }
                }
            }
            .scrollContentBackground(.hidden)
            .background(.black)
            .tint(.white)
            .navigationTitle("注册")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { Button("返回登录") { dismiss() } }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { focusedField = nil }
                }
            }
            .buttonStyle(.liquidGlass)
            .alert("在线", isPresented: Binding(get: { online.message != nil }, set: { if !$0 { online.message = nil } })) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text(online.message ?? "")
            }
        }
        .background(.black)
    }
}

private struct LeaderboardSheet: View {
    @EnvironmentObject private var online: OnlineSyncManager
    var track: OnlineTrackSummary

    var body: some View {
        NavigationStack {
            List {
                if online.leaderboard.isEmpty {
                    Text("暂无圈速")
                        .foregroundStyle(.secondary)
                }
                ForEach(online.leaderboard) { entry in
                    HStack {
                        Text("#\(entry.rank)").font(.headline.monospacedDigit())
                        VStack(alignment: .leading) {
                            Text(entry.username)
                            Text("\(Int(entry.speedKph)) km/h · GPS ±\(Int(entry.gpsAccuracy))m")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let telemetryText = telemetryText(for: entry) {
                                Text(telemetryText)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(formatLap(entry.lapTimeMs)).font(.headline.monospacedDigit())
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(.black)
            .navigationTitle(track.trackName)
            .buttonStyle(.liquidGlass)
        }
        .background(.black)
    }

    private func formatLap(_ milliseconds: Int) -> String {
        let minutes = milliseconds / 60000
        let seconds = (milliseconds % 60000) / 1000
        let millis = milliseconds % 1000
        return String(format: "%d:%02d.%03d", minutes, seconds, millis)
    }

    private func telemetryText(for entry: OnlineLeaderboardEntry) -> String? {
        let throttle = entry.analysis?.throttleScore ?? entry.throttleScore
        let brake = entry.analysis?.brakeScore ?? entry.brakeScore
        let deviation = entry.analysis?.lineDeviationAvg ?? entry.lineDeviationAvg
        guard throttle != nil || brake != nil || deviation != nil else { return nil }
        return "油门 \(throttle ?? 0)% · 刹车 \(brake ?? 0)% · 偏离 \(String(format: "%.1f", deviation ?? 0))m"
    }
}

private struct LapState {
    var trackID: String?
    var startedAt: Date?
    var samples: [LapSample] = []
    var wasNearStart = false
    private var lastSampleAt = Date.distantPast

    init(trackID: String? = nil) {
        self.trackID = trackID
    }

    mutating func restart(at date: Date, firstPose: FusedPose, track: TrackData) {
        startedAt = date
        samples = []
        lastSampleAt = .distantPast
        append(pose: firstPose, track: track)
    }

    mutating func append(pose: FusedPose, track: TrackData) {
        guard Date().timeIntervalSince(lastSampleAt) > 0.4 else { return }
        lastSampleAt = Date()
        samples.append(LapSample(
            latitude: pose.coordinate.latitude,
            longitude: pose.coordinate.longitude,
            speed: pose.speed * 3.6,
            color: "green",
            acceleration: pose.longitudinalAcceleration,
            longitudinalAcceleration: pose.longitudinalAcceleration,
            lateralAcceleration: pose.lateralAcceleration,
            lineDeviationMeters: GeoConverter.lineDeviationMeters(from: pose.coordinate, along: track.points)
        ))
        if samples.count > 700 { samples.removeFirst(samples.count - 700) }
    }
}

private struct EmptyBody: Encodable {}
private struct CodeRequest: Encodable { var email: String }
private struct RegisterRequest: Encodable { var username: String; var password: String; var email: String; var code: String }
private struct LoginRequest: Encodable { var login: String; var password: String }
private struct ErrorResponse: Decodable { var error: String? }
private struct CodeResponse: Decodable { var ok: Bool; var emailSent: Bool; var message: String? }
private struct AuthResponse: Decodable { var ok: Bool; var token: String; var user: OnlineUser }
private struct MeResponse: Decodable { var ok: Bool; var user: OnlineUser }
private struct TracksResponse: Decodable { var ok: Bool; var tracks: [OnlineTrackSummary] }
private struct TrackUploadResponse: Decodable { var ok: Bool; var track: OnlineTrackSummary; var remoteID: String }
private struct TrackDownloadResponse: Decodable { var ok: Bool; var track: OnlineDownloadedTrack }
private struct LeaderboardResponse: Decodable { var ok: Bool; var leaderboard: [OnlineLeaderboardEntry] }
private struct LapUploadResponse: Decodable { var ok: Bool; var analysis: OnlineLapAnalysis? }

private struct TrackUploadRequest: Encodable {
    var trackName: String
    var trackLength: Double
    var cornerCount: Int
    var points: [LapSample]

    init(track: TrackData) {
        trackName = track.trackName
        trackLength = track.trackLength
        cornerCount = track.cornerCount
        points = track.points.map { LapSample(latitude: $0.latitude, longitude: $0.longitude, speed: $0.speed, color: $0.color.rawValue) }
    }
}

private struct LapUploadRequest: Encodable {
    var lapTimeMs: Int
    var speedKph: Double
    var gpsAccuracy: Double
    var samples: [LapSample]
}

private struct LapSample: Codable, Hashable {
    var latitude: Double
    var longitude: Double
    var speed: Double
    var color: String
    var acceleration: Double? = nil
    var longitudinalAcceleration: Double? = nil
    var lateralAcceleration: Double? = nil
    var lineDeviationMeters: Double? = nil
}

private struct OnlineDownloadedTrack: Decodable {
    var remoteID: String
    var trackName: String
    var trackLength: Double
    var cornerCount: Int
    var points: [OnlineDownloadedPoint]

    func asTrackData() -> TrackData {
        TrackData(
            remoteID: remoteID,
            trackName: trackName,
            trackLength: trackLength,
            cornerCount: cornerCount,
            points: points.map { TrackPoint(latitude: $0.latitude, longitude: $0.longitude, speed: $0.speed, color: TrackPointColor(rawValue: $0.color) ?? .green) },
            importedAt: Date()
        )
    }
}

private struct OnlineDownloadedPoint: Decodable {
    var latitude: Double
    var longitude: Double
    var speed: Double
    var color: String
}

private enum OnlineError: LocalizedError {
    case invalidURL
    case invalidResponse
    case notLoggedIn
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "服务器地址无效"
        case .invalidResponse: return "服务器响应无效"
        case .notLoggedIn: return "请先登录"
        case .server(let message): return message
        }
    }
}
