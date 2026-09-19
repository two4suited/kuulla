import Foundation
import SwiftData

// Local mirror of the API's Playlist (src/Kuulla.Api/Models/Playlist.cs), conforming to
// Syncable per the EpisodeStateRecord precedent. `id` matches the server-assigned playlist id.
@Model
final class PlaylistRecord: Syncable {
    @Attribute(.unique) var id: String
    var name: String
    var type: PlaylistType
    // Embedded rather than a separate SwiftData relationship, matching the server's embedded
    // PlaylistItem list — items are always read/written with their parent playlist.
    var items: [PlaylistItemRecord]
    var createdAt: Date
    var updatedAt: Date
    var isDirty: Bool
    // Present only when type == .dynamic. Stored inline like `items`, matching the server's
    // embedded DynamicPlaylistConfig field on Playlist.
    var dynamicConfig: DynamicPlaylistConfigRecord?
    // Curated emoji from PlaylistIcons.curated, or nil for "no icon" (falls back to the default
    // glyph). Mirrors the server's nullable Playlist.Icon; travels in the sync payload and
    // reconciles last-write-wins like `name` (#439). Optional so adding it is a lightweight
    // SwiftData migration.
    var icon: String?
    var accentColor: String?
    // Per-playlist "what plays when an episode finishes" override (#629); nil inherits the show /
    // global setting. Optional so adding it is a lightweight SwiftData migration.
    var playNextBehavior: PlayNextBehavior?
    // Automatically queue items added after this playlist has synced to the device.
    var autoDownload: Bool = false
    // Tombstone flag (#400). A sync response entry with deleted == true means the playlist was
    // deleted on another device; PlaylistSyncAdapter.apply removes the local row instead of
    // upserting it. Defaulted so adding it is a lightweight SwiftData migration, and so locally
    // created rows are always live.
    var deleted: Bool = false

    init(
        id: String,
        name: String,
        type: PlaylistType,
        items: [PlaylistItemRecord] = [],
        createdAt: Date,
        updatedAt: Date,
        isDirty: Bool = false,
        dynamicConfig: DynamicPlaylistConfigRecord? = nil,
        icon: String? = nil,
        accentColor: String? = nil,
        playNextBehavior: PlayNextBehavior? = nil,
        autoDownload: Bool = false,
        deleted: Bool = false
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.items = items
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isDirty = isDirty
        self.dynamicConfig = dynamicConfig
        self.icon = icon
        self.accentColor = accentColor
        self.playNextBehavior = playNextBehavior
        self.autoDownload = autoDownload
        self.deleted = deleted
    }
}

// Local mirror of the API's PlaylistItem. Not itself a @Model — it's embedded on PlaylistRecord
// exactly as PlaylistItem is embedded on the server's Playlist document, so it's a plain Codable
// value type stored inline rather than a separate SwiftData entity.
struct PlaylistItemRecord: Codable {
    var episodeId: String
    var showId: String
    var addedAt: Date
    // Lexicographically sortable rank string (LexoRank-style), not an integer index — see
    // Kuulla.Api.Models.PlaylistItem for why (concurrent last-write-wins reorder/insert safety).
    var order: String
}

// Mirrors the API's Kuulla.Api.Models.PlaylistType enum, including its raw values, since the
// wire format is a plain integer (see UnlistenedEpisodeCount for the same convention).
enum PlaylistType: Int, Codable {
    case manual = 0
    case dynamic = 1
}

// Local mirror of the API's Kuulla.Api.Models.DynamicPlaylistConfig. Not a @Model for the same
// reason as PlaylistItemRecord — it's embedded on PlaylistRecord, not a standalone entity.
struct DynamicPlaylistConfigRecord: Codable {
    var showIds: [String]
    // Nil means unlimited — mirrors the server's nullable Kuulla.Api.Models.DynamicPlaylistConfig.MaxEpisodes.
    var maxEpisodes: Int?
    var priorityList: [String]
}

// An immutable, value-type snapshot of a playlist for list rendering (#511). PlaylistsView and
// LibraryView's playlist shelf build these straight from the local PlaylistRecord sync store so
// they paint instantly and refresh behind the visible list, instead of blocking on a live
// PlaylistClient fetch — and being a plain struct keeps the ordering/filtering logic below
// unit-testable without a ModelContext or the network.
struct PlaylistSummary: Identifiable, Equatable {
    let id: String
    let name: String
    let icon: String?
    let accentColor: String?
    let itemCount: Int

    init(id: String, name: String, icon: String?, accentColor: String?, itemCount: Int) {
        self.id = id
        self.name = name
        self.icon = icon
        self.accentColor = accentColor
        self.itemCount = itemCount
    }

    init(record: PlaylistRecord) {
        self.init(
            id: record.id, name: record.name, icon: record.icon,
            accentColor: record.accentColor, itemCount: record.items.count)
    }

    // For the optimistic append after PlaylistClient.createPlaylist, before the next sync pulls
    // the server's authoritative row into SwiftData.
    init(playlist: Playlist) {
        self.init(
            id: playlist.id, name: playlist.name, icon: playlist.icon,
            accentColor: playlist.accentColor, itemCount: playlist.items.count)
    }

    // Local-store rows → the ordered list the UI shows: drop tombstoned rows (#400), optionally
    // drop the "Up Next" queue playlist (LibraryView gives it a dedicated shelf tile), and sort
    // by name to match the ordering the API-fed list used.
    static func list(from records: [PlaylistRecord], excludingUpNext: Bool) -> [PlaylistSummary] {
        records
            .filter { !$0.deleted }
            .filter { !excludingUpNext || $0.name != UpNextView.upNextPlaylistName }
            .map(PlaylistSummary.init(record:))
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // Reads the local sync store directly and summarizes it — the fetch half of
    // PlaylistsView.readLocalPlaylists, shared with CarPlaySceneDelegate (#758) so both surfaces
    // derive "all playlists, Up Next included" from the same query instead of each re-issuing it.
    static func local(in context: ModelContext, excludingUpNext: Bool = false) -> [PlaylistSummary] {
        let records = (try? context.fetch(FetchDescriptor<PlaylistRecord>())) ?? []
        return list(from: records, excludingUpNext: excludingUpNext)
    }
}

extension PlaylistDetail {
    // Builds a PlaylistDetail-shaped snapshot from the local sync store, resolving each item's
    // title/artwork against CatalogCache when available (best-effort — a show the cache hasn't
    // seen yet just shows the existing "(episode unavailable)" placeholder text until a network
    // fetch lands). Shared by PlaylistDetailView (phone) and CarPlaySceneDelegate (car, #758) so
    // both paint instantly from the same locally-synced PlaylistRecord before their own
    // network/sync refresh, rather than each hand-rolling this resolution separately.
    static func local(id: String, in context: ModelContext) -> PlaylistDetail? {
        guard let record = try? context.fetch(
            FetchDescriptor<PlaylistRecord>(predicate: #Predicate { $0.id == id })
        ).first, !record.deleted else { return nil }

        // Resolve each distinct show once (not once per item), mirroring
        // PlaylistService.GetPlaylistDetailAsync's server-side comment for the same reason — a
        // playlist with many episodes from the same show shouldn't re-fetch that show's cached
        // episode list per item.
        let showIds = Set(record.items.map(\.showId))
        let episodesByShow = Dictionary(uniqueKeysWithValues: showIds.map {
            ($0, CatalogCache.episodes(showId: $0, in: context))
        })
        let showsById = Dictionary(uniqueKeysWithValues: showIds.map {
            ($0, CatalogCache.show(id: $0, in: context))
        })

        let items = record.items
            .sorted { $0.order < $1.order }
            .map { item -> PlaylistItemDetail in
                let episode = episodesByShow[item.showId]?.first { $0.id == item.episodeId }
                let show = showsById[item.showId] ?? nil
                return PlaylistItemDetail(
                    episodeId: item.episodeId, showId: item.showId,
                    title: episode?.title, artworkUrl: show?.artworkUrl,
                    addedAt: item.addedAt, order: item.order)
            }

        return PlaylistDetail(
            id: record.id, name: record.name, type: record.type, items: items,
            createdAt: record.createdAt, updatedAt: record.updatedAt,
            dynamicConfig: record.dynamicConfig.map {
                DynamicPlaylistConfig(showIds: $0.showIds, maxEpisodes: $0.maxEpisodes, priorityList: $0.priorityList)
            },
            icon: record.icon, accentColor: record.accentColor,
            playNextBehavior: record.playNextBehavior,
            autoDownload: record.autoDownload)
    }
}
