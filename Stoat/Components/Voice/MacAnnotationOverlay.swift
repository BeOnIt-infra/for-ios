//
//  MacAnnotationOverlay.swift
//  Revolt
//
//  Be On It: shows annotation strokes on the presenter's real screen while
//  they share it -- the behaviour Android and the Windows client have, where
//  whoever is being drawn on sees the marks over whatever app they're
//  actually using, not just inside the chat window.
//
//  iOS can't do this: its capture runs in a separate broadcast process and
//  the platform has no equivalent of Android's TYPE_APPLICATION_OVERLAY.
//  macOS can, through an NSWindow that floats above everything and passes
//  clicks through. Catalyst can't import AppKit, but it runs inside a real
//  AppKit process, so the window is reachable through the Objective-C
//  runtime -- and every property needed here is KVC-compliant, which avoids
//  hand-rolling objc_msgSend for the non-object arguments.
//
//  Note this reaches AppKit from Catalyst, which Apple documents no support
//  for. It is stable in practice (NSWindow's properties are long-standing
//  public AppKit API, only the route to them is unofficial) but it is worth
//  knowing about before an App Store submission.
//

#if targetEnvironment(macCatalyst)

import SwiftUI
import UIKit

/// Identifies the overlay's SwiftUI scene, and doubles as the window title
/// used to find its NSWindow among the app's windows.
let macAnnotationOverlayWindowID = "beonit-annotation-overlay"

/// Draws the shared annotation state edge to edge with a clear background.
/// Coordinates are normalised 0-1 against the shared video, and the Mac
/// shares a whole display, so they map straight onto the screen.
struct MacAnnotationOverlayView: View {
    @ObservedObject var controller: AnnotationController

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { _ in
            Canvas { context, size in
                for stroke in controller.strokes where stroke.points.count >= 2 {
                    var path = Path()
                    for (i, p) in stroke.points.enumerated() {
                        let pt = CGPoint(x: p.x * size.width, y: p.y * size.height)
                        if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                    }
                    context.stroke(
                        path,
                        with: .color(ThemeColor(hex: stroke.color).color),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
                    )
                }

                let now = Date()
                for (_, laser) in controller.lasers {
                    for p in laser.points {
                        let age = now.timeIntervalSince(p.t)
                        guard age < laserFadeSeconds else { continue }
                        let alpha = max(0, min(1, 1 - age / laserFadeSeconds))
                        let radius = 5 * alpha + 3
                        let pt = CGPoint(x: p.x * size.width, y: p.y * size.height)
                        context.fill(
                            Path(ellipseIn: CGRect(x: pt.x - radius, y: pt.y - radius, width: radius * 2, height: radius * 2)),
                            with: .color(ThemeColor(hex: laser.color).color.opacity(alpha))
                        )
                    }
                }
            }
        }
        .ignoresSafeArea()
        .background(Color.clear)
        // The window ignores mouse events outright, but this keeps SwiftUI
        // from treating the canvas as interactive in the meantime.
        .allowsHitTesting(false)
    }
}

/// Carries the live call's annotation state to the overlay scene, which is a
/// separate window and so gets none of the call view's environment.
final class MacOverlayBridge: ObservableObject {
    static let shared = MacOverlayBridge()
    @Published var controller: AnnotationController?
    private init() {}
}

/// Root of the overlay scene. Names its own window so the styling code can
/// pick it out of NSApplication.windows, then hands it over to be styled.
struct MacAnnotationOverlayHost: View {
    @ObservedObject private var bridge = MacOverlayBridge.shared

    var body: some View {
        ZStack {
            Color.clear
            if let controller = bridge.controller {
                MacAnnotationOverlayView(controller: controller)
            }
        }
        .background(SceneNamer())
        .ignoresSafeArea()
    }
}

/// Sets the hosting scene's title -- on Catalyst that becomes the NSWindow's
/// title, which is how the window is identified for styling.
private struct SceneNamer: UIViewRepresentable {
    func makeUIView(context _: Context) -> UIView { NamingView() }
    func updateUIView(_: UIView, context _: Context) {}

    private final class NamingView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window, let scene = window.windowScene else { return }
            scene.title = macAnnotationOverlayWindowID
            // Catalyst's own supported way to drop the title bar; the AppKit
            // styleMask change covers the rest of the chrome.
            scene.titlebar?.titleVisibility = .hidden
            scene.titlebar?.toolbar = nil
            clearBackgrounds()
            MacAnnotationOverlayWindow.diag("didMoveToWindow: scene titled, starting styling")
            MacAnnotationOverlayWindow.styleWhenReady()
        }

        // The NSWindow is already transparent (diagnostics confirmed
        // opaque=0), so any remaining black is UIKit painting over it: the
        // UIWindow, the hosting controller's view, and SwiftUI's own layers
        // each carry a background. They are re-set as SwiftUI lays out, so
        // clearing once in didMoveToWindow isn't enough.
        override func layoutSubviews() {
            super.layoutSubviews()
            clearBackgrounds()
        }

        private func clearBackgrounds() {
            window?.rootViewController?.view.backgroundColor = .clear
            window?.rootViewController?.view.isOpaque = false
            var view: UIView? = self
            while let current = view {
                current.backgroundColor = .clear
                current.isOpaque = false
                view = current.superview
            }
        }
    }
}

enum MacAnnotationOverlayWindow {
    /// Turns the scene's backing window into a pass-through heads-up layer.
    ///
    /// Keeps re-applying rather than stopping at the first success: the
    /// window exists well before SwiftUI and UIKit have finished configuring
    /// it, and whatever they do afterwards would otherwise win.
    static func styleWhenReady(seconds: Double = 5) {
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                style()
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    /// Temporary: records what the styling pass actually sees. Writes to a
    /// fixed path rather than a container-relative one, since this build
    /// isn't sandboxed and the container path guess was wrong once already.
    static func diag(_ text: String) {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("beonit-overlay-diag.txt")
        let line = "\(Date()): \(text)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    @discardableResult
    static func style() -> Bool {
        guard let window = overlayWindow() else {
            diag("no match. titles=\(allWindowTitles())")
            return false
        }
        diag("matched window, applying")

        // Borderless: the scene opens as an ordinary titled window, and a
        // title bar on a full-screen overlay is both visible and draggable.
        window.setValue(NSNumber(value: 0), forKey: "styleMask")
        // Above normal windows and the menu bar, below the screen saver, so
        // it sits over other apps without blocking system UI outright.
        window.setValue(NSNumber(value: 1000), forKey: "level")
        // The whole point: clicks land on whatever is underneath.
        window.setValue(NSNumber(value: true), forKey: "ignoresMouseEvents")
        window.setValue(NSNumber(value: false), forKey: "opaque")
        window.setValue(NSNumber(value: false), forKey: "hasShadow")
        window.setValue(NSNumber(value: false), forKey: "movable")
        // This is a heads-up layer, not a document: it has no business in the
        // Window menu, in window cycling, or as something to close.
        window.setValue(NSNumber(value: true), forKey: "excludedFromWindowsMenu")
        // canJoinAllSpaces | stationary | ignoresCycle | fullScreenAuxiliary
        // -- follows the user across Spaces, survives another app going full
        // screen (exactly when someone is being walked through something),
        // and stays out of window cycling.
        window.setValue(NSNumber(value: 1 | 16 | 64 | 256), forKey: "collectionBehavior")

        if let colorClass = NSClassFromString("NSColor") as AnyObject?,
           let clear = colorClass.perform(NSSelectorFromString("clearColor"))?.takeUnretainedValue() {
            window.setValue(clear, forKey: "backgroundColor")
        }

        // Cover the whole screen including the menu bar strip; a titled
        // window opens at some arbitrary default size.
        if let screen = (window.perform(NSSelectorFromString("screen"))?.takeUnretainedValue()) as AnyObject?,
           let frameValue = screen.value(forKey: "frame") as? NSValue {
            window.setValue(frameValue, forKey: "frame")
        }

        window.perform(NSSelectorFromString("orderFrontRegardless"))
        diag("applied. styleMask=\(String(describing: window.value(forKey: "styleMask"))) level=\(String(describing: window.value(forKey: "level"))) opaque=\(String(describing: window.value(forKey: "opaque")))")
        return true
    }

    static func allWindowTitles() -> String {
        guard let appClass = NSClassFromString("NSApplication") as AnyObject?,
              let app = appClass.perform(NSSelectorFromString("sharedApplication"))?.takeUnretainedValue() as AnyObject?,
              let windows = app.perform(NSSelectorFromString("windows"))?.takeUnretainedValue() as? [AnyObject]
        else { return "<no NSApplication>" }
        return windows.map { w in
            let t = (w.value(forKey: "title") as? String) ?? "<nil>"
            return "[\(type(of: w)) '\(t)']"
        }.joined(separator: ", ")
    }

    /// The overlay scene's NSWindow, identified by the title SwiftUI gave it.
    private static func overlayWindow() -> AnyObject? {
        guard let appClass = NSClassFromString("NSApplication") as AnyObject?,
              let app = appClass.perform(NSSelectorFromString("sharedApplication"))?.takeUnretainedValue() as AnyObject?,
              let windows = app.perform(NSSelectorFromString("windows"))?.takeUnretainedValue() as? [AnyObject]
        else { return nil }

        return windows.first { window in
            (window.value(forKey: "title") as? String) == macAnnotationOverlayWindowID
        }
    }
}

#endif
