import WebKit

@MainActor
final class WarmCacheBridge: NSObject, WKScriptMessageHandlerWithReply {
    weak var owner: BrowserWindowController?

    init(owner: BrowserWindowController) {
        self.owner = owner
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        let host = message.frameInfo.securityOrigin.host.lowercased()
        guard message.frameInfo.isMainFrame,
              AppSecurityPolicy.isMediaCaptureHost(host),
              let request = message.body as? [String: Any],
              let operation = request["op"] as? String,
              let path = request["path"] as? String,
              path.count <= 2048,
              AppSecurityPolicy.conversationURL(forPath: path) != nil,
              let owner else {
            replyHandler("cold-spa", nil)
            return
        }
        switch operation {
        case "query": replyHandler(owner.warmCacheDecision(for: path), nil)
        case "prewarm": replyHandler(owner.prewarmConversation(for: path), nil)
        default: replyHandler("ignored", nil)
        }
    }
}
