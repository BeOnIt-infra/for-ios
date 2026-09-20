//
//  Whiteboard.swift
//  Revolt
//
//  Be On It: the call's shared whiteboard. It is the same board that lives at
//  <board url>/board/<id> on the web, shown here in a WKWebView rather than
//  reimplemented -- that is what gives it a link you can send to someone who
//  isn't in the call, and what keeps its contents after the call ends, since
//  that page saves them. It replaces an earlier version that relayed tldraw's
//  own store updates across the WebView boundary on a "whiteboard" topic; the
//  web client no longer speaks that protocol, so a phone running it would have
//  drawn on a board nobody else could see.
//
//  Which board a call is using is agreed over the call's data channel: whoever
//  opens it first picks an id and tells everyone else. The id is never derived
//  from the channel or the call, because anyone holding it can open the board
//  without signing in, so it has to be unguessable rather than merely unique.
//  See Whiteboard.tsx in the web client for the other half of this.
//

import SwiftUI
import WebKit
import Security

/// How long to wait for someone else's board before starting one. Long enough
/// to cross a call, short enough not to look stuck.
private let claimTimeoutSeconds: Double = 0.9

/// Agrees with the rest of the call on which board to open.
///
/// There is only ever one whiteboard visible at a time for this device, so a
/// shared instance (matching MacOverlayBridge's pattern elsewhere in this
/// target) is simpler than threading a reference through the view hierarchy
/// down to wherever the RoomDelegate callback lives.
final class WhiteboardBridge: ObservableObject {
    static let shared = WhiteboardBridge()

    /// The board this call settled on, once it has one: either the one
    /// somebody answered with, or the one we picked when nobody did. Only
    /// touched on the main thread, since it drives a view.
    @Published private(set) var boardId: String?

    /// Set by VoiceChannelView to actually publish over LiveKit; this class
    /// has no room reference of its own.
    var onSend: ((Data) -> Void)?

    private var claim: DispatchWorkItem?

    private init() {}

    /// Ask the call which board it is on, and start one if nobody answers.
    /// Main thread only, like everything else here that touches `boardId`.
    func begin() {
        guard claim == nil else { return }

        publish(["type": "request_board"])

        let claim = DispatchWorkItem { [weak self] in
            guard let self, self.boardId == nil else { return }
            let id = Self.newBoardId()
            self.boardId = id
            self.publish(["type": "board", "id": id])
        }
        self.claim = claim
        DispatchQueue.main.asyncAfter(deadline: .now() + claimTimeoutSeconds, execute: claim)
    }

    /// Called when the call ends, so the next call opens its own board rather
    /// than reopening this one's.
    func end() {
        claim?.cancel()
        claim = nil
        boardId = nil
        onSend = nil
    }

    /// Call from the RoomDelegate when a "whiteboard-link" packet arrives.
    func handleIncoming(_ data: Data) {
        guard let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch event["type"] as? String {
                case "board":
                    // Someone else's board wins over ours only before we have
                    // one; two people opening at the same instant would
                    // otherwise keep swapping.
                    guard let id = event["id"] as? String, Self.isValidId(id), self.boardId == nil else { return }
                    self.claim?.cancel()
                    self.boardId = id
                case "request_board":
                    if let id = self.boardId {
                        self.publish(["type": "board", "id": id])
                    }
                default:
                    ()
            }
        }
    }

    private func publish(_ event: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: event) else { return }
        onSend?(data)
    }

    /// 16 random bytes, base64url -- the same shape the web client makes, so a
    /// board started on either side is addressable by the other.
    private static func newBoardId() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            // Only reachable if the system RNG itself fails. A board nobody
            // can guess is the whole point, so don't fall back to a weaker one.
            return UUID().uuidString
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The id arrives from another participant and goes straight into a URL,
    /// so it is checked rather than trusted: base64url characters only, and no
    /// longer than one we would have made ourselves.
    private static func isValidId(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 43 && id.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || character == "-" || character == "_")
        }
    }
}

struct WhiteboardView: View {
    /// Where the board is served from -- the client-call deployment, not the
    /// chat API.
    let boardUrl: String

    /// The name on this person's cursor for everyone else on the board. The
    /// board has no accounts of its own, so without this they show up as a
    /// guest. Deliberately not part of the link the board offers to copy:
    /// that one is for other people.
    let displayName: String?

    @ObservedObject private var bridge = WhiteboardBridge.shared

    var body: some View {
        ZStack {
            if let id = bridge.boardId, let url = boardURL(for: id) {
                BoardWebView(url: url)
            } else {
                ProgressView()
            }
        }
        .onAppear { bridge.begin() }
    }

    private func boardURL(for id: String) -> URL? {
        guard var components = URLComponents(string: "\(boardUrl)/board/\(id)") else { return nil }
        if let displayName, !displayName.isEmpty {
            components.queryItems = [URLQueryItem(name: "name", value: displayName)]
        }
        return components.url
    }
}

private struct BoardWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.allowsInlineMediaPlayback = true

        let view = WKWebView(frame: .zero, configuration: config)
#if DEBUG
        view.isInspectable = true
#endif
        // The board pans and zooms its own canvas; letting the scroll view
        // bounce underneath it makes both feel broken.
        view.scrollView.bounces = false

        view.load(URLRequest(url: url))
        context.coordinator.loaded = url
        return view
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // SwiftUI re-runs this for any redraw, and reloading throws away the
        // canvas -- so only when the board being shown actually changed.
        guard context.coordinator.loaded != url else { return }
        context.coordinator.loaded = url
        webView.load(URLRequest(url: url))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var loaded: URL?
    }
}
