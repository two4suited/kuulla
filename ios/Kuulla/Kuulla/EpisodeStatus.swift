import SwiftData
import SwiftUI

// Shared New/In Progress/Played/Auto-Played taxonomy derived from a local EpisodeStateRecord (or
// its absence), so FeedView, ShowDetailView, and EpisodeDetailView don't each hand-roll the same
// classification.
enum EpisodeStatus: Equatable {
    case new
    case inProgress
    case played
    // Completed by the unlistened-episode-limit enforcement job rather than the user (#97/#100) —
    // distinct from .played so the UI can offer a "Restore" undo instead of treating it as final.
    case autoPlayed

    init(record: EpisodeStateRecord?) {
        guard let record else {
            self = .new
            return
        }
        if record.completed && record.autoPlayed {
            self = .autoPlayed
        } else if record.completed {
            self = .played
        } else if record.positionSeconds > 0 {
            self = .inProgress
        } else {
            self = .new
        }
    }

    var label: String {
        switch self {
        case .new: "New"
        case .inProgress: "In Progress"
        case .played: "Played"
        case .autoPlayed: "Auto-marked Played"
        }
    }

    var tintColor: Color {
        switch self {
        case .new: .blue
        case .inProgress: .orange
        case .played: .green
        case .autoPlayed: .gray
        }
    }
}

extension EpisodeStatus {
    // Local-only status lookup for a set of episode ids, shared by FeedView and ShowDetailView so
    // each row-list screen doesn't hand-roll the same fetch-and-classify query.
    static func statusMap(for episodeIds: Set<String>, in context: ModelContext) -> [String: EpisodeStatus] {
        let descriptor = FetchDescriptor<EpisodeStateRecord>(predicate: #Predicate { episodeIds.contains($0.id) })
        let records = (try? context.fetch(descriptor)) ?? []
        return Dictionary(uniqueKeysWithValues: records.map { ($0.id, EpisodeStatus(record: $0)) })
    }

    // Status + positionSeconds + archived-flag from a single fetch, for ShowDetailView's filter
    // chips, progress bar, and auto-archive (#187) visibility filtering — avoids extra SwiftData
    // queries over the same record set.
    static func statusAndPositionMaps(
        for episodeIds: Set<String>, in context: ModelContext
    ) -> (statuses: [String: EpisodeStatus], positions: [String: Int], archived: Set<String>) {
        let descriptor = FetchDescriptor<EpisodeStateRecord>(predicate: #Predicate { episodeIds.contains($0.id) })
        let records = (try? context.fetch(descriptor)) ?? []
        let statuses = Dictionary(uniqueKeysWithValues: records.map { ($0.id, EpisodeStatus(record: $0)) })
        let positions = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0.positionSeconds) })
        let archived = Set(records.filter(\.archived).map(\.id))
        return (statuses, positions, archived)
    }
}

// Shared pill rendering for an EpisodeStatus, used by both FeedView's episode rows and
// EpisodeDetailView's header so the two don't each hand-roll the same badge styling.
struct StatusBadge: View {
    let status: EpisodeStatus

    var body: some View {
        Text(status.label)
            .font(.caption2)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(status.tintColor.opacity(0.15))
            .foregroundStyle(status.tintColor)
            .clipShape(Capsule())
    }
}

// Trailing status indicator for an episode row: the badge, plus a "Restore" action when the
// episode was auto-marked played (#100). Shared by FeedView and ShowDetailView's episode rows.
struct StatusBadgeWithRestore: View {
    let status: EpisodeStatus
    let onRestore: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            StatusBadge(status: status)
            if status == .autoPlayed {
                Button("Restore", action: onRestore)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }
}
