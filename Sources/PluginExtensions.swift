import Foundation

enum PluginKind: String, Codable, CaseIterable {
    case audio
    case lyrics
}

struct InstalledPlugin: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var kind: PluginKind
    var endpointURL: String
    var queryParam: String = "q"
    var audioURLKeyPath: String = "url"
    var lyricsKeyPath: String = "lyrics"
    var syncedLyricsKeyPath: String = "syncedLyrics"
    var headers: [String: String] = [:]
    var isEnabled: Bool = true
}

@MainActor
final class PluginStore: ObservableObject {
    static let shared = PluginStore()

    @Published var plugins: [InstalledPlugin] = [] {
        didSet { save() }
    }

    private let storageKey = "custom_json_plugins_v1"

    private init() {
        load()
    }

    func add(_ plugin: InstalledPlugin) {
        plugins.append(plugin)
    }

    func remove(at offsets: IndexSet, kind: PluginKind) {
        let filtered = plugins.filter { $0.kind == kind }
        let idsToDelete = offsets.map { filtered[$0].id }
        plugins.removeAll { idsToDelete.contains($0.id) }
    }

    func toggle(_ plugin: InstalledPlugin) {
        guard let idx = plugins.firstIndex(where: { $0.id == plugin.id }) else { return }
        plugins[idx].isEnabled.toggle()
    }

    func importFromJSONData(_ data: Data, fallbackKind: PluginKind) throws {
        if let single = try? JSONDecoder().decode(InstalledPlugin.self, from: data) {
            plugins.append(single)
            return
        }
        if let list = try? JSONDecoder().decode([InstalledPlugin].self, from: data) {
            plugins.append(contentsOf: list)
            return
        }
        if let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let url = (raw["endpointURL"] ?? raw["url"] ?? raw["endpoint"]) as? String, !url.isEmpty {
            let name = (raw["name"] as? String) ?? URL(string: url)?.host ?? "Custom Extension"
            let kindStr = (raw["kind"] as? String)?.lowercased()
            let kind: PluginKind = (kindStr == "lyrics") ? .lyrics : (kindStr == "audio" ? .audio : fallbackKind)
            let plugin = InstalledPlugin(
                name: name,
                kind: kind,
                endpointURL: url,
                queryParam: (raw["queryParam"] as? String) ?? "q",
                audioURLKeyPath: (raw["audioURLKeyPath"] as? String) ?? "url",
                lyricsKeyPath: (raw["lyricsKeyPath"] as? String) ?? "lyrics",
                syncedLyricsKeyPath: (raw["syncedLyricsKeyPath"] as? String) ?? "syncedLyrics"
            )
            plugins.append(plugin)
            return
        }
        throw NSError(domain: "PluginImport", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON plugin format"])
    }

    private func save() {
        if let data = try? JSONEncoder().encode(plugins) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([InstalledPlugin].self, from: data)
        else { return }
        plugins = decoded
    }
}

enum PluginRuntime {
    static func resolveAudioStream(for track: Track) async -> URL? {
        let active = await MainActor.run {
            PluginStore.shared.plugins.filter { $0.kind == .audio && $0.isEnabled }
        }
        guard !active.isEmpty else { return nil }

        for plugin in active {
            if let url = await queryAudio(plugin: plugin, track: track) {
                return url
            }
        }
        return nil
    }

     static func fetchLyrics(title: String, artist: String, videoId: String, duration: Double) async -> [LyricsCandidate] {
        let active = await MainActor.run {
            PluginStore.shared.plugins.filter { $0.kind == .lyrics && $0.isEnabled }
        }
        guard !active.isEmpty else { return [] }

        var results: [LyricsCandidate] = []
        for plugin in active {
            if let candidate = await queryLyrics(plugin: plugin, title: title, artist: artist, videoId: videoId, duration: duration) {
                results.append(candidate)
            }
        }
        return results
    }

    private static func buildRequestURL(plugin: InstalledPlugin, query: String, videoId: String, title: String, artist: String) -> URL? {
        let raw = plugin.endpointURL
            .replacingOccurrences(of: "{query}", with: query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")
            .replacingOccurrences(of: "{videoId}", with: videoId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")
            .replacingOccurrences(of: "{title}", with: title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")
            .replacingOccurrences(of: "{artist}", with: artist.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")

        guard var comps = URLComponents(string: raw) else { return nil }
        if !plugin.endpointURL.contains("{query}") && !plugin.endpointURL.contains("{videoId}") {
            var items = comps.queryItems ?? []
            items.append(URLQueryItem(name: plugin.queryParam, value: query))
            if !videoId.isEmpty { items.append(URLQueryItem(name: "videoId", value: videoId)) }
            comps.queryItems = items
        }
        return comps.url
    }

    private static func queryAudio(plugin: InstalledPlugin, track: Track) async -> URL? {
        let q = "\(track.title) \(track.artist)".trimmingCharacters(in: .whitespaces)
        guard let reqURL = buildRequestURL(plugin: plugin, query: q, videoId: track.videoId, title: track.title, artist: track.artist) else { return nil }
        var req = URLRequest(url: reqURL)
        req.timeoutInterval = 8
        for (k, v) in plugin.headers { req.setValue(v, forHTTPHeaderField: k) }

        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) else { return nil }

        if let foundStr = extractString(from: json, keyPath: plugin.audioURLKeyPath),
           let streamURL = URL(string: foundStr) {
            return streamURL
        }
        return nil
    }

        private static func queryLyrics(plugin: InstalledPlugin, title: String, artist: String, videoId: String, duration: Double) async -> LyricsCandidate? {
        let q = "\(title) \(artist)".trimmingCharacters(in: .whitespaces)
        guard let reqURL = buildRequestURL(plugin: plugin, query: q, videoId: videoId, title: title, artist: artist) else { return nil }
        var req = URLRequest(url: reqURL)
        req.timeoutInterval = 8
        for (k, v) in plugin.headers { req.setValue(v, forHTTPHeaderField: k) }

        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) else { return nil }

        if let lrc = extractString(from: json, keyPath: plugin.syncedLyricsKeyPath), !lrc.isEmpty {
            let parsed = parseLRC(lrc)
            if !parsed.isEmpty {
                let res = LyricsResult(lines: parsed, plain: nil, synced: true, raw: lrc)
                return LyricsCandidate(provider: plugin.name, trackName: title, artistName: artist, result: res, score: 85)
            }
        }
        if let plain = extractString(from: json, keyPath: plugin.lyricsKeyPath), !plain.isEmpty {
            let res = LyricsResult(lines: [], plain: plain, synced: false, raw: plain)
            return LyricsCandidate(provider: plugin.name, trackName: title, artistName: artist, result: res, score: 60)
        }
        return nil
    }

    private static func parseLRC(_ text: String) -> [LyricLine] {
        let pattern = #"\[(\d{1,2}):(\d{2})(?:[\.:](\d{1,3}))?\](.*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var lines: [LyricLine] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let ns = rawLine as NSString
            let range = NSRange(location: 0, length: ns.length)
            guard let m = regex.firstMatch(in: rawLine, range: range), m.numberOfRanges >= 5 else { continue }
            let minVal = Double(ns.substring(with: m.range(at: 1))) ?? 0
            let secVal = Double(ns.substring(with: m.range(at: 2))) ?? 0
            var fracVal: Double = 0
            if m.range(at: 3).location != NSNotFound {
                let fracStr = ns.substring(with: m.range(at: 3))
                let denom = pow(10.0, Double(fracStr.count))
                fracVal = (Double(fracStr) ?? 0) / denom
            }
            let lyricText = ns.substring(with: m.range(at: 4)).trimmingCharacters(in: .whitespaces)
            lines.append(LyricLine(time: minVal * 60 + secVal + fracVal, text: lyricText))
        }
        return lines.sorted { $0.time < $1.time }
    }

    private static func extractString(from object: Any, keyPath: String) -> String? {
        let parts = keyPath.split(separator: ".").map(String.init)
        var current: Any? = object
        for part in parts {
            if let dict = current as? [String: Any] {
                current = dict[part]
            } else if let arr = current as? [Any], let idx = Int(part), arr.indices.contains(idx) {
                current = arr[idx]
            } else {
                return nil
            }
        }
        return current as? String
    }
}
