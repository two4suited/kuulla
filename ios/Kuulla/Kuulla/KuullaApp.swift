import GoogleSignIn
import SwiftUI

@main
struct KuullaApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .task {
                    await AuthManager.shared.restorePreviousSignIn()
                }
                .onOpenURL { url in
                    GIDSignIn.sharedInstance.handle(url)
                }
        }
    }
}
