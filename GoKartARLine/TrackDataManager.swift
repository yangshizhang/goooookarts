import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class TrackDataManager: ObservableObject {
    @Published private(set) var tracks: [TrackData] = []
    @Published var selectedTrackID: TrackData.ID?
    @Published var errorMessage: String?

    private let storeURL: URL
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init() {
        storeURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("ImportedTracks.json")
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        loadTracks()
    }

    var selectedTrack: TrackData? {
        guard let selectedTrackID else { return tracks.first }
        return tracks.first { $0.id == selectedTrackID }
    }

    func importFile(from url: URL) {
        do {
            let hasAccess = url.startAccessingSecurityScopedResource()
            defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            let track = url.pathExtension.lowercased() == "gpx" ? try GPXTrackConverter.convert(data: data, fallbackName: url.deletingPathExtension().lastPathComponent) : try decoder.decode(TrackData.self, from: data)
            try validate(track)
            tracks.append(track)
            selectedTrackID = track.id
            saveTracks()
        } catch { errorMessage = "导入失败：\(error.localizedDescription)" }
    }

    func addGeneratedTrack(_ track: TrackData) {
        tracks.append(track)
        selectedTrackID = track.id
        saveTracks()
    }

    func setRemoteID(for trackID: TrackData.ID, remoteID: String) {
        guard let index = tracks.firstIndex(where: { $0.id == trackID }) else { return }
        tracks[index].remoteID = remoteID
        saveTracks()
    }

    func deleteTracks(at offsets: IndexSet) {
        tracks.remove(atOffsets: offsets)
        if let selectedTrackID, !tracks.contains(where: { $0.id == selectedTrackID }) { self.selectedTrackID = tracks.first?.id }
        saveTracks()
    }

    func delete(track: TrackData) {
        tracks.removeAll { $0.id == track.id }
        if let selectedTrackID, !tracks.contains(where: { $0.id == selectedTrackID }) { self.selectedTrackID = tracks.first?.id }
        saveTracks()
    }

    func rename(track: TrackData, to name: String) {
        guard let index = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        tracks[index].trackName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        saveTracks()
    }

    private func loadTracks() {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }
        do {
            tracks = try decoder.decode([TrackData].self, from: Data(contentsOf: storeURL))
            selectedTrackID = tracks.first?.id
        } catch { errorMessage = "读取本地赛道失败：\(error.localizedDescription)" }
    }

    private func saveTracks() {
        do { try encoder.encode(tracks).write(to: storeURL, options: [.atomic]) }
        catch { errorMessage = "保存赛道失败：\(error.localizedDescription)" }
    }

    private func validate(_ track: TrackData) throws {
        guard !track.trackName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TrackImportError.missingTrackName }
        guard track.points.count >= 100 else { throw TrackImportError.tooFewPoints }
        for point in track.points where !(-90...90).contains(point.latitude) || !(-180...180).contains(point.longitude) { throw TrackImportError.invalidCoordinate }
    }
}

enum TrackImportError: LocalizedError {
    case missingTrackName, tooFewPoints, invalidCoordinate
    var errorDescription: String? {
        switch self {
        case .missingTrackName: return "trackName不能为空"
        case .tooFewPoints: return "轨迹点至少需要100个"
        case .invalidCoordinate: return "经纬度超出WGS84合法范围"
        }
    }
}

final class GPXTrackConverter: NSObject, XMLParserDelegate {
    private var points: [TrackPoint] = []

    static func convert(data: Data, fallbackName: String) throws -> TrackData {
        let converter = GPXTrackConverter()
        let parser = XMLParser(data: data)
        parser.delegate = converter
        guard parser.parse() else { throw parser.parserError ?? TrackImportError.tooFewPoints }
        return TrackData(trackName: fallbackName, trackLength: converter.length, cornerCount: 0, points: converter.points, importedAt: Date())
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        guard elementName == "trkpt" || elementName == "rtept", let lat = Double(attributeDict["lat"] ?? ""), let lon = Double(attributeDict["lon"] ?? "") else { return }
        points.append(TrackPoint(latitude: lat, longitude: lon, speed: 50, color: .green))
    }

    private var length: Double {
        zip(points, points.dropFirst()).reduce(0) { $0 + GeoConverter.distanceMeters(from: $1.0.coordinate, to: $1.1.coordinate) }
    }
}

