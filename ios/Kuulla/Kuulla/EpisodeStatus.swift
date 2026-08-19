import SwiftUI

// Shared New/In Progress/Played taxonomy derived from a local EpisodeStateRecord (or its absence),
// so FeedView and EpisodeDetailView don't each hand-roll the same three-way classification.
enum EpisodeStatus: Equatable {
    case new
    case inProgress
    case played

    init(record: EpisodeStateRecord?) {
        guard let record else {
            self = .new
            return
        }
        if record.completed {
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
        }
    }

    var tintColor: Color {
        switch self {
        case .new: .blue
        case .inProgress: .orange
        case .played: .green
        }
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
