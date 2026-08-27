import SafariServices
import SwiftUI

// Wraps SFSafariViewController so a chapter/sponsor link can be opened in-app (as a sheet) rather
// than backgrounding the app into the system Safari — matters here specifically because opening it
// mid-episode shouldn't interrupt playback (AudioPlayer keeps running regardless either way, but
// staying in-app keeps the player screen one tap away instead of a full app-switch).
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}
