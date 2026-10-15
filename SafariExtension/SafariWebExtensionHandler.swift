import Foundation
import SafariServices
import DCModel

/// Receives `browser.runtime.sendNativeMessage` calls from the Safari flavor of the web extension,
/// drops them in the shared inbox, wakes the app, and answers `{ok: true}`.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let request = context.inputItems.first as? NSExtensionItem
        let message = request?.userInfo?[SFExtensionMessageKey] ?? [String: Any]()

        let reply: [String: Any]
        do {
            var payload = try IncomingMessage.payload(from: message, defaultBrowser: "safari")
            payload.browser = "safari"
            if let file = try IncomingMessage.deliver(payload) {
                // Contents/PlugIns/<this>.appex → the app.
                IncomingMessage.wakeApp(for: file, preferring: IncomingMessage.enclosingApp(of: Bundle.main.bundleURL, levels: 3))
            }
            IncomingMessage.log.info("Delivered \(payload.kind.rawValue, privacy: .public) from Safari")
            reply = ["ok": true]
        } catch {
            IncomingMessage.log.error("Rejected a Safari message: \(String(describing: error), privacy: .public)")
            reply = ["ok": false, "error": String(describing: error)]
        }

        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: reply]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }
}
