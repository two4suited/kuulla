import CarPlay
import UIKit

// Connects/tears down the CPInterfaceController for CarPlay's template scene. The browse UI
// (subscriptions/episodes) that replaces the placeholder root template below is wired in #117.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    var interfaceController: CPInterfaceController?

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        interfaceController.setRootTemplate(Self.placeholderRootTemplate, animated: false, completion: nil)
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        self.interfaceController = nil
    }

    private static var placeholderRootTemplate: CPListTemplate {
        CPListTemplate(title: "Kuulla", sections: [])
    }
}
