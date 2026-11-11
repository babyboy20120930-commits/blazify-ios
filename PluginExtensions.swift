import Foundation
import SwiftUI

/// Represents a BitChord-style JSON plugin for either Lyrics or Audio streaming.
struct CustomPlugin: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case lyrics
        case audio
    }

    var id: UUID = UUID()
    var name: String
    var kind: Kind
    var enabled: Bool = true
    /// URL template for lyrics or audio stream resolution.
    /// Supported placeholders: {title}, {artist}, {duration}, {id}, {query}
    var endpoint: String
    /// Optional search endpoint for audio plugins that require search-then-stream.
    var searchEndpoint: String? = nil
    /// JSON key path for synced LRC lyrics (for lyrics plugins) or stream URL (for audio plugins).
    var primaryField: String? = nil
    /// Optional fallback JSON key path for plain lyrics.
    var secondaryField: String? = nil
}

@MainActor
final class PluginManager: ObservableObject {
    static let shared = PluginManager()

    @Published var plugins: [CustomPlugin] = [] {
        didSet { save() }
    }

    private let storageKey = "customJsonPlugins_v1"

    private init() {
        load()
    }

    var activeLyricsPlugins: [CustomPlugin] {
        plugins.filter { $0.enabled && $0.kind == .lyrics }
    }

    var activeAudioPlugins: [CustomPlugin] {
        plugins.filter { $0.enabled && $0.kind == .audio }
    }

    func toggle(_ id: UUID) {
        if let idx = plugins.firstIndex(where: { $0.id == id }) {
            plugins[idx].enabled.toggle()
        }
    }

    func remove(_ id: UUID) {
        plugins.removeAll { $0.id == id }
    }

    /// Imports one or multiple plugins from raw JSON text (supports single object, array, or BitChord-style wrapper).
    func importFromJSONText(_ raw: String) throws -> Int {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else {
            throw NSError(domain: "PluginManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid UTF-8 text"])
        }

        var imported: [CustomPlugin] = []

        if let single = try? JSONDecoder().decode(FlexiblePluginDTO.self, from: data),
           let plugin = single.toPlugin() {
            imported.append(plugin)
        } else if let list = try? JSONDecoder().decode([FlexiblePluginDTO].self, from: data) {
            imported.append(contentsOf: list.compactMap { $0.toPlugin() })
        } else if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let arr = obj["plugins"] as? [[String: Any]] ?? obj["extensions"] as? [[String: Any]] {
                for item in arr {
                    if let subData = try? JSONSerialization.data(withJSONObject: item),
                       let dto = try? JSONDecoder().decode(FlexiblePluginDTO.self, from: subData),
                       let plugin = dto.toPlugin() {
                        imported.append(plugin)
                    }
                }
            }
        }

        guard !imported.isEmpty else {
            throw NSError(domain: "PluginManager", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Unrecognized JSON plugin format. Needs 'name' and 'url' / 'streamUrl'."])
        }

        for p in imported {
            if let existingIdx = plugins.firstIndex(where: { $0.name == p.name && $0.kind == p.kind }) {
                plugins[existingIdx] = p
            } else {
                plugins.append(p)
            }
        }
        return imported.count
    }

    /// Downloads a JSON manifest from a remote URL and installs it.
    func importFromURL(_ urlString: String) async throws -> Int {
        let cleaned = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: cleaned), url.scheme?.hasPrefix("http") == true else {
            throw NSError(domain: "PluginManager", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP/HTTPS URL"])
        }
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "PluginManager", code: 4, userInfo: [NSLocalizedDescriptionKey: "Empty response from URL"])
        }
        return try importFromJSONText(text)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(plugins) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let saved = try? JSONDecoder().decode([CustomPlugin].self, from: data) else {
            return
        }
        plugins = saved
    }
}

/// Flexible decoder supporting multiple common JSON schema styles (BitChord, LrcLib, generic API).
private struct FlexiblePluginDTO: Decodable {
    let name: String?
    let title: String?
    let type: String?
    let kind: String?
    let url: String?
    let endpoint: String?
    let lyricsUrl: String?
    let streamUrl: String?
    let searchUrl: String?
    let syncedField: String?
    let plainField: String?
    let urlField: String?

    func toPlugin() -> CustomPlugin? {
        let resolvedName = (name ?? title ?? "Custom Plugin").trimmingCharacters(in: .whitespacesAndNewlines)
        let rawType = (type ?? kind ?? "").lowercased()

        if rawType == "audio" || rawType == "source" || streamUrl != nil {
            guard let ep = streamUrl ?? url ?? endpoint, !ep.isEmpty else { return nil }
            return CustomPlugin(
                name: resolvedName,
                kind: .audio,
                endpoint: ep,
                searchEndpoint: searchUrl,
                primaryField: urlField ?? "url"
            )
        } else {
            guard let ep = lyricsUrl ?? url ?? endpoint, !ep.isEmpty else { return nil }
            return CustomPlugin(
                name: resolvedName,
                kind: .lyrics,
                endpoint: ep,
                primaryField: syncedField ?? "syncedLyrics",
                secondaryField: plainField ?? "plainLyrics"
            )
        }
    }
}

/// Runtime executor for active JSON plugins.
enum PluginRuntime {
    static func fill(_ template: String, title: String, artist: String, duration: Double = 0, id: String = "") -> URL? {
        let encTitle = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? title
        let encArtist = artist.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? artist
        let encQuery = "\(title) \(artist)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let encId = id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? id

        let filled = template
            .replacingOccurrences(of: "{title}", with: encTitle)
            .replacingOccurrences(of: "{artist}", with: encArtist)
            .replacingOccurrences(of: "{query}", with: encQuery)
            .replacingOccurrences(of: "{id}", with: encId)
            .replacingOccurrences(of: "{duration}", with: "\(Int(duration))")

        return URL(string: filled)
    }

    /// Queries all enabled JSON lyrics plugins concurrently.
    static func fetchLyrics(title: String, artist: String, videoId: String, duration: Double) async -> [LyricsCandidate] {
        let active = await MainActor.run { PluginManager.shared.activeLyricsPlugins }
        guard !active.isEmpty else { return [] }

        return await withTaskGroup(of: LyricsCandidate?.self) { group in
            for plugin in active {
                group.addTask {
                    guard let url = fill(plugin.endpoint, title: title, artist: artist, duration: duration, id: videoId),
                          let (data, _) = try? await URLSession.shared.data(from: url) else {
                        return nil
                    }
                    // Support raw LRC text response directly
                    if let rawText = String(data: data, encoding: .utf8),
                       rawText.contains("[0"), !rawText.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
                        let parsed = Lyrics.parseLRC(rawText)
                        if !parsed.isEmpty {
                            let res = LyricsResult(lines: parsed, plain: nil, synced: true, raw: rawText)
                            return LyricsCandidate(provider: plugin.name, trackName: title, artistName: artist, result: res, score: 95)
                        }
                    }
                    // Parse JSON dictionary or array
                    guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
                    let dict: [String: Any]?
                    if let d = json as? [String: Any] {
                        dict = (d["data"] as? [String: Any]) ?? d
                    } else if let arr = json as? [[String: Any]] {
                        dict = arr.first
                    } else {
                        dict = nil
                    }
                    guard let dict else { return nil }

                    let syncedKey = plugin.primaryField ?? "syncedLyrics"
                    let plainKey = plugin.secondaryField ?? "plainLyrics"
                    let syncedStr = (dict[syncedKey] as? String) ?? (dict["lrc"] as? String) ?? (dict["lyrics"] as? String)
                    let plainStr = (dict[plainKey] as? String) ?? (dict["text"] as? String)

                    if let s = syncedStr, !s.isEmpty {
                        let lines = Lyrics.parseLRC(s)
                        if !lines.isEmpty {
                            let res = LyricsResult(lines: lines, plain: plainStr, synced: true, raw: s)
                            return LyricsCandidate(provider: plugin.name, trackName: title, artistName: artist, result: res, score: 95)
                        }
                    }
                        let parsed = Lyrics.parseLRC(rawText)
                        if !parsed.isEmpty {
                            let res = LyricsResult(lines: parsed, plain: nil, synced: true, raw: rawText)
                            return LyricsCandidate(provider: plugin.name, trackName: title, artistName: artist, result: res, score: 95)
                        }
                    }
                    // Parse JSON dictionary or array
                    guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
                    let dict: [String: Any]?
                    if let d = json as? [String: Any] {
                        dict = (d["data"] as? [String: Any]) ?? d
                    } else if let arr = json as? [[String: Any]] {
                        dict = arr.first
                    } else {
                        dict = nil
                    }
                    guard let dict else { return nil }

                    let syncedKey = plugin.primaryField ?? "syncedLyrics"
                    let plainKey = plugin.secondaryField ?? "plainLyrics"
                    let syncedStr = (dict[syncedKey] as? String) ?? (dict["lrc"] as? String) ?? (dict["lyrics"] as? String)
                    let plainStr = (dict[plainKey] as? String) ?? (dict["text"] as? String)

                    if let s = syncedStr, !s.isEmpty {
                        let lines = Lyrics.parseLRC(s)
                        if !lines.isEmpty {
                            let res = LyricsResult(lines: lines, plain: plainStr, synced: true, raw: s)
                            return LyricsCandidate(provider: plugin.name, trackName: title, artistName: artist, result: res, score: 95)
                        }
                    }
                    if let p = plainStr, !p.isEmpty {
                        let res = LyricsResult(lines: [], plain: p, synced: false, raw: p)
                        return LyricsCandidate(provider: plugin.name, trackName: title, artistName: artist, result: res, score: 60)
                    }
                    return nil
                }
            }

            var results: [LyricsCandidate] = []
            for await item in group {
                if let item { results.append(item) }
            }
            return results
        }
    }

    /// Queries enabled JSON audio plugins to resolve a playable stream URL.
    static func resolveAudioStream(for track: Track) async -> (url: URL, duration: Double)? {
        let active = await MainActor.run { PluginManager.shared.activeAudioPlugins }
        guard !active.isEmpty else { return nil }

        for plugin in active {
            guard let url = fill(plugin.endpoint, title: track.title, artist: track.artist, duration: track.duration, id: track.videoId),
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let json = try? JSONSerialization.jsonObject(with: data) else {
                continue
            }
            let dict: [String: Any]?
            if let d = json as? [String: Any] {
                dict = (d["data"] as? [String: Any]) ?? d
            } else if let arr = json as? [[String: Any]] {
                dict = arr.first
            } else {
                dict = nil
            }
            guard let dict else { continue }

            let field = plugin.primaryField ?? "url"
            if let urlStr = (dict[field] as? String) ?? (dict["streamUrl"] as? String) ?? (dict["url"] as? String),
               let streamURL = URL(string: urlStr) {
                let dur = (dict["duration"] as? Double) ?? track.duration
                return (streamURL, dur)
            }
        }
        return nil
    }
}
