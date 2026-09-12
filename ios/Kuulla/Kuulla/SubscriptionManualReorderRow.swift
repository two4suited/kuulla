import SwiftUI

// Compact row for the drag-to-reorder List shown when SubscriptionSortOrder.manual is active
// (#438). Shared by LibraryView and SubscriptionsView.
struct SubscriptionManualReorderRow: View {
    let subscription: Subscription
    let unplayedCount: UnplayedCounts.Count?
    var isInProgress = false

    var body: some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: subscription.showArtworkUrl.flatMap(URL.init), pointSize: 44) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Color.secondary.opacity(0.2)
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Text(subscription.showTitle)
                .font(.subheadline)
                .lineLimit(2)

            Spacer(minLength: 0)

            if isInProgress {
                Image(systemName: "waveform")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(KuullaColor.warning)
                    .accessibilityLabel("In progress")
            }

            if let unplayedCount, unplayedCount.unplayed > 0 {
                Text(unplayedCount.hitCap ? "\(unplayedCount.unplayed)+" : "\(unplayedCount.unplayed)")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.accentColor, in: Capsule())
            }
        }
    }
}
