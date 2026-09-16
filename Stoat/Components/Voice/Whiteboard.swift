//
//  Whiteboard.swift
//  Revolt
//
//  Be On It: shared whiteboard for a voice call, backed by the real tldraw
//  editor running in a WKWebView. Neither iOS nor Mac Catalyst has a tldraw
//  SDK of their own, and this device is already an authenticated
//  participant in the call's real LiveKit room -- so rather than have the
//  WebView open a second connection as the same identity (which LiveKit
//  would treat as a duplicate session), data-channel bytes are relayed
//  across the WebView boundary instead: JS -> Swift via
//  window.webkit.messageHandlers.whiteboard.postMessage, Swift -> JS by
//  calling the page's window.__onNativeWhiteboardMessage directly, base64
//  round-tripped so the JSON can never break out of the JS string literal
//  it's embedded in. See whiteboardSync.ts and whiteboardEmbed.tsx in the
//  web client for the other half of this.
//
//  Wiring this up to an actual call (VoiceChannelView.swift):
//    1. Set `WhiteboardBridge.shared.onSend` alongside where
//       annotationController.onSend is set, publishing on topic
//       "whiteboard" the same way "annotate" is published.
//    2. In the RoomDelegate's `room(_:participant:didReceiveData:forTopic:)`,
//       add `if topic == "whiteboard" { WhiteboardBridge.shared.handleIncoming(data); return }`
//       before the existing `guard topic == "annotate"` line.
//    3. Clear `WhiteboardBridge.shared.onSend` (and `.webView`) wherever
//       annotationController.onSend is cleared on call teardown.
//    4. Show `WhiteboardView(baseURL: viewState.apiInfo?.app)` in place of
//       the video grid when a new `@State var showWhiteboard` is toggled,
//       and add a toolbar button next to the screen-share one to flip it.
//

import SwiftUI
import WebKit

private let whiteboardTopic = "whiteboard"

/// Bridges the whiteboard's WKWebView to the call's LiveKit room. There is
/// only ever one whiteboard visible at a time for this device, so a shared
/// instance (matching MacOverlayBridge's pattern elsewhere in this target)
/// is simpler than threading a reference through the view hierarchy down to
/// wherever the RoomDelegate callback lives.
final class WhiteboardBridge {
    static let shared = WhiteboardBridge()

    weak var webView: WKWebView?
    /// Set by VoiceChannelView to actually publish over LiveKit; this class
    /// has no room reference of its own.
    var onSend: ((Data) -> Void)?

    private init() {}

    /// Call from the RoomDelegate when a "whiteboard"-topic packet arrives.
    func handleIncoming(_ data: Data) {
        guard let json = String(data: data, encoding: .utf8) else { return }
        let encoded = Data(json.utf8).base64EncodedString()
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(
                "window.__onNativeWhiteboardMessage && " +
                "window.__onNativeWhiteboardMessage(decodeURIComponent(escape(window.atob('\(encoded)'))))"
            )
        }
    }
}

struct WhiteboardView: UIViewRepresentable {
    /// The deployment's web app origin (`ApiInfo.app`, e.g.
    /// "https://stoat.example.nip.io") -- fetched from the server at
    /// runtime rather than hardcoded, so this follows the same migration
    /// path as everything else if the deployment's domain ever changes.
    let baseURL: String?

    final class Coordinator: NSObject, WKScriptMessageHandler {
        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "whiteboard", let json = message.body as? String else { return }
            WhiteboardBridge.shared.onSend?(Data(json.utf8))
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "whiteboard")

        let config = WKWebViewConfiguration()
        config.userContentController = controller
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let view = WKWebView(frame: .zero, configuration: config)
#if DEBUG
        view.isInspectable = true
#endif

        if let baseURL, let url = URL(string: "\(baseURL)/whiteboard-embed.html") {
            view.load(URLRequest(url: url))
        }

        WhiteboardBridge.shared.webView = view
        return view
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        if WhiteboardBridge.shared.webView === webView {
            WhiteboardBridge.shared.webView = nil
        }
    }
}
