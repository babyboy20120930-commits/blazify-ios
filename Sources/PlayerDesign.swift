import Foundation

/// The player artwork layouts.
enum PlayerDesign: String, CaseIterable, Identifiable {
    case classic, ring, fullArt, record, cassette, video

    /// Visible themes in the Player theme picker (Video Art is moved to the dedicated Watch MV player).
    static var allCases: [PlayerDesign] {
        [.classic, .ring, .fullArt, .record, .cassette]
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic: String(localized: "Classic")
        case .ring: String(localized: "Ring")
        case .fullArt: String(localized: "Full Art")
        case .record: String(localized: "Record")
        case .cassette: String(localized: "Cassette")
        case .video: String(localized: "Video Art")
        }
    }

    var subtitle: String {
        switch self {
        case .classic: "Square album art"
        case .ring: "Circular art with a progress ring"
        case .fullArt: "Art fills the whole screen"
        case .record: "Spinning vinyl record"
        case .cassette: "Retro cassette tape"
        case .video: "The song's own video, in step"
        }
    }
}
