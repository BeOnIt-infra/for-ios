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
            guard let scene = window?.windowScene else { return }
            scene.title = macAnnotationOverlayWindowID
            MacAnnotationOverlayWindow.styleWhenReady()
        }
    }
}

enum MacAnnotationOverlayWindow {
    /// Turns the scene's backing window into a pass-through heads-up layer.
    ///
    /// Called repeatedly after the window is asked for, because the scene
    /// connects asynchronously -- there's no callback that says "your
    /// NSWindow exists now".
    static func styleWhenReady(attempts: Int = 20) {
        Task { @MainActor in
            for _ in 0 ..< attempts {
                if style() { return }
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    @discardableResult
    static func style() -> Bool {
        guard let window = overlayWindow() else { return false }

        // Above normal windows and the menu bar, below the screen saver, so
        // it sits over other apps without blocking system UI outright.
        window.setValue(NSNumber(value: 1000), forKey: "level")
        // The whole point: clicks land on whatever is underneath.
        window.setValue(NSNumber(value: true), forKey: "ignoresMouseEvents")
        window.setValue(NSNumber(value: false), forKey: "opaque")
        window.setValue(NSNumber(value: false), forKey: "hasShadow")
        // canJoinAllSpaces | stationary | fullScreenAuxiliary -- follows the
        // user across Spaces and survives another app going full screen,
        // which is exactly when someone is being walked through something.
        window.setValue(NSNumber(value: 1 | 16 | 256), forKey: "collectionBehavior")

        if let colorClass = NSClassFromString("NSColor") as AnyObject?,
           let clear = colorClass.perform(NSSelectorFromString("clearColor"))?.takeUnretainedValue() {
            window.setValue(clear, forKey: "backgroundColor")
        }

        window.perform(NSSelectorFromString("orderFrontRegardless"))

        // Cover the whole screen: a titled window opens at some default size.
        if let screen = (window.perform(NSSelectorFromString("screen"))?.takeUnretainedValue()) as AnyObject?,
           let frameValue = screen.value(forKey: "frame") as? NSValue {
            window.setValue(frameValue, forKey: "frame")
        }
        return true
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
