import Foundation

/// Snapshot of what's currently playing on the iPhone, pushed to the paired watch over
/// `WatchConnectivitySession` (#582). `artworkThumbnail` is a small downsampled JPEG — the
/// full-resolution artwork never crosses the wire, keeping the application context payload small.
struct WatchNowPlayingState: Codable, Equatable {
    let episodeId: String
    let showId: String
    let title: String
    let showTitle: String?
    let artworkThumbnail: Data?
    let position: TimeInterval
    let duration: TimeInterval
    let isPlaying: Bool
}
