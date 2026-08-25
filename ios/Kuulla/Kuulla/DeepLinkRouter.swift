import Foundation
import Observation

// Holds a route to navigate to once ContentView is ready to act on it — set from outside the
// view hierarchy (AppDelegate's UNUserNotificationCenterDelegate, for a tapped push notification)
// since a background/terminated-launch tap has no view to hand a route to directly (#218).
@Observable
final class DeepLinkRouter {
    static let shared = DeepLinkRouter()

    var pendingRoute: CatalogRoute?

    private init() {}
}

// Pure mapping from a push notification's payload to where it should navigate — split out from
// the UNUserNotificationCenterDelegate glue so it's unit testable with a plain dictionary.
// UNNotification/UNNotificationResponse have no public initializers, so the delegate methods
// themselves aren't directly testable (same limitation PushNotificationManager's
// NotificationAuthorizing seam works around for UNNotificationSettings).
enum PushNotificationRouting {
    // Matches ApnsNotificationService's payload shape (src/Kuulla.Api/Services/
    // ApnsNotificationService.cs): "showId" always present, "episodeId" only when the push named
    // exactly one new episode — multiple new episodes route to the show instead of guessing which
    // episode the user meant.
    static func route(from userInfo: [AnyHashable: Any]) -> CatalogRoute? {
        guard let showId = userInfo["showId"] as? String else { return nil }
        if let episodeId = userInfo["episodeId"] as? String {
            return .episode(showId: showId, episodeId: episodeId)
        }
        return .show(id: showId)
    }
}
