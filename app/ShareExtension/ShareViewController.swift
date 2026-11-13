import Intents
import SwiftUI
import UIKit

/// Fish Pocket in the share sheet: what another app shares goes to a new conversation or a
/// Bot's chat. The engine lives in the app, so nothing is sent from here: what was shared is
/// copied into the App Group container as the sheet opens (`ShareModel`), and picking where
/// it goes opens the app there, with it in the composer.
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        model.finish = { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) }
        model.cancel = { [weak self] in self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled)) }
        model.openApp = { [weak self] url in self?.open(url) ?? false }

        let host = UIHostingController(rootView: ShareView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)

        // Opened from the share sheet's top row: the Bot or group is already chosen.
        if let intent = extensionContext?.intent as? INSendMessageIntent,
           let target = intent.conversationIdentifier.flatMap(ShareInbox.Target.init(conversation:)) {
            model.preset = (target, intent.speakableGroupName?.spokenPhrase ?? intent.recipients?.first?.displayName ?? "")
        }
        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        model.load(items.flatMap { $0.attachments ?? [] })
    }

    /// An extension has no `UIApplication.shared`, but the application object is up the
    /// responder chain, and it opens the app's own `dsh://` link. false: nothing up there could.
    private func open(_ url: URL) -> Bool {
        typealias Open = @convention(c) (AnyObject, Selector, URL, [UIApplication.OpenExternalURLOptionsKey: Any], (@convention(block) (Bool) -> Void)?) -> Void
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication, application.responds(to: selector) {
                let open = unsafeBitCast(application.method(for: selector), to: Open.self)
                open(application, selector, url, [:], nil)
                return true
            }
            responder = current.next
        }
        return false
    }
}
