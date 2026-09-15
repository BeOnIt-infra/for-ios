//
//  AnnotationOverlay.swift
//  Revolt
//
//  Be On It: draw / laser-pointer overlay for a screen-share tile in a call.
//
//  Mirrors the web/Android `AnnotationOverlay` -- strokes and laser positions
//  are broadcast to everyone else in the call over LiveKit's data channel
//  (topic "annotate") as JSON, with no server state and nothing persisted.
//  The wire format matches the other clients exactly, so annotations drawn
//  here show up for web/desktop/Android viewers and vice-versa.
//
//  iOS has no public API for drawing an always-on-top overlay over other
//  apps or the system screen (unlike Android's TYPE_APPLICATION_OVERLAY),
//  and screen share here captures the whole device via ReplayKit rather
//  than just this app's own UI -- so there is no iOS equivalent of the
//  Android "draw straight onto the presenter's real screen" mode. Everyone,
//  including the presenter, sees strokes overlaid on the screen-share tile
//  within the app, the same as every other viewer.
//

import Foundation
import SwiftUI

struct AnnotationPoint {
    var x: Double
    var y: Double
    var t: Date
}

struct AnnotationStroke: Identifiable {
    let id: String
    /// Identity of whoever drew this, taken from the verified sender of the
    /// packet rather than its payload, so nobody can annotate as someone else.
    let author: String
    /// Identity of whoever's screen this was drawn on. Annotations used to be
    /// room-scoped, so with two people sharing at once the same stroke landed
    /// on both tiles. nil means it came from a client that predates this
    /// field, and is shown everywhere as it used to be.
    let target: String?
    let color: String
    var points: [AnnotationPoint]
    /// Set once stroke_end arrives; finished strokes accept no more points.
    var done: Bool = false
}

struct AnnotationLaser {
    var color: String
    /// See AnnotationStroke.target.
    var target: String?
    var points: [AnnotationPoint]
}

private let annotationColors = ["#ef4444", "#f97316", "#eab308", "#22c55e", "#3b82f6"]
/// Shared with AnnotationScreenshot's compositing in ReplayBufferRecorder.swift.
let laserFadeSeconds: TimeInterval = 0.8
/// Minimum movement before another point is sent, in normalised units --
/// matches the web/Android overlays so all clients load the data channel
/// the same way.
private let minPointDistance: Double = 0.004
/// Hard caps so a long call can't grow the stroke list without bound.
private let maxStrokes = 400
private let maxPointsPerStroke = 2000

/// Room-scoped: every screen-share tile in a call renders from this same
/// shared state (matching web/Android, where every AnnotationOverlay
/// instance listens to the same global "annotate" topic rather than being
/// scoped per-track).
final class AnnotationController: ObservableObject {
    @Published private(set) var strokes: [AnnotationStroke] = []
    /// Keyed by sender, then by the share being drawn on ("" when unknown),
    /// so one person pointing at two shares doesn't overwrite themselves.
    @Published private(set) var lasers: [String: AnnotationLaser] = [:]

    var myId: String = ""
    /// Set by the room delegate wiring; publishes to LiveKit's data channel.
    var onSend: ((_ payload: [String: Any], _ reliable: Bool) -> Void)?

    private var laserPruneTimer: Timer?

    init() {
        // Laser dots were only ever dropped when the next laser event
        // arrived, and only hidden by the views re-rendering and checking
        // each point's age. That works while something keeps redrawing --
        // but the Mac overlay is a background, never-key window, where
        // SwiftUI stops ticking TimelineView, so the last dots stayed frozen
        // on screen until something else forced a redraw. Expiring them here
        // publishes the change, which redraws every surface on its own.
        let timer = Timer(timeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            self?.pruneExpiredLasers()
        }
        // .common, so it keeps firing while menus or tracking loops are up.
        RunLoop.main.add(timer, forMode: .common)
        laserPruneTimer = timer
    }

    deinit {
        laserPruneTimer?.invalidate()
    }

    private func pruneExpiredLasers() {
        guard !lasers.isEmpty else { return }
        let now = Date()
        var next: [String: AnnotationLaser] = [:]
        var changed = false
        for (id, laser) in lasers {
            var laser = laser
            let kept = laser.points.filter { now.timeIntervalSince($0.t) < laserFadeSeconds }
            if kept.count != laser.points.count { changed = true }
            guard !kept.isEmpty else { continue }
            laser.points = kept
            next[id] = laser
        }
        // Only publish on a real change, so an idle call isn't invalidating
        // the view fifteen times a second.
        guard changed else { return }
        lasers = next
    }

    /// - Parameter senderId: identity of whoever published this event --
    ///   always the transport's view of the sender (or our own id for the
    ///   local echo), never what the payload claims.
    func applyEvent(_ json: [String: Any], senderId: String) {
        guard let type = json["type"] as? String else { return }
        switch type {
        case "stroke_start":
            guard let id = json["id"] as? String else { return }
            let color = json["color"] as? String ?? annotationColors[0]
            let x = json["x"] as? Double ?? 0
            let y = json["y"] as? Double ?? 0
            var next = strokes
            next.append(AnnotationStroke(
                id: id, author: senderId, target: json["target"] as? String, color: color,
                points: [AnnotationPoint(x: x, y: y, t: Date())]
            ))
            strokes = next.count > maxStrokes ? Array(next.suffix(maxStrokes)) : next

        case "stroke_point":
            guard let id = json["id"] as? String else { return }
            let x = json["x"] as? Double ?? 0
            let y = json["y"] as? Double ?? 0
            strokes = strokes.map { s in
                guard s.id == id, s.author == senderId, !s.done, s.points.count < maxPointsPerStroke else { return s }
                var s = s
                s.points.append(AnnotationPoint(x: x, y: y, t: Date()))
                return s
            }

        case "stroke_end":
            guard let id = json["id"] as? String else { return }
            strokes = strokes.map { s in
                guard s.id == id, s.author == senderId else { return s }
                var s = s
                s.done = true
                return s
            }

        case "laser":
            let color = json["color"] as? String ?? annotationColors[0]
            let x = json["x"] as? Double ?? 0
            let y = json["y"] as? Double ?? 0
            let target = json["target"] as? String
            let key = "\(senderId)|\(target ?? "")"
            var laser = lasers[key] ?? AnnotationLaser(color: color, target: target, points: [])
            laser.color = color
            laser.target = target
            laser.points = laser.points.filter { Date().timeIntervalSince($0.t) < laserFadeSeconds }
            laser.points.append(AnnotationPoint(x: x, y: y, t: Date()))
            lasers[key] = laser

        // Scoped to the sender's own strokes: everyone in the call may
        // publish on this topic, so a global wipe would let anyone erase
        // other people's annotations.
        case "clear":
            // Whoever's screen is being shared may wipe it clean, marks and
            // all -- it's their screen. Anyone else clears only what they
            // drew themselves. Either way it is scoped to one share.
            let target = json["target"] as? String
            let ownerClearingOwnShare = target != nil && target == senderId
            strokes = strokes.filter { stroke in
                if let target, stroke.target != target { return true }
                if ownerClearingOwnShare { return false }
                return stroke.author != senderId
            }

        default: break
        }
    }

    /// Marks to draw on one share. A nil `target` on a mark means it came
    /// from a client that predates per-share scoping, so it is shown on every
    /// share rather than disappearing.
    func visibleStrokes(for target: String?) -> [AnnotationStroke] {
        strokes.filter { $0.target == nil || $0.target == target }
    }

    func visibleLasers(for target: String?) -> [AnnotationLaser] {
        lasers.values.filter { $0.target == nil || $0.target == target }
    }

    private func send(_ payload: [String: Any], reliable: Bool) {
        onSend?(payload, reliable)
    }

    func localStrokeStart(id: String, color: String, x: Double, y: Double, target: String?) {
        var event: [String: Any] = ["type": "stroke_start", "id": id, "color": color, "x": x, "y": y]
        if let target { event["target"] = target }
        applyEvent(event, senderId: myId)
        send(event, reliable: true)
    }

    func localStrokePoint(id: String, x: Double, y: Double) {
        let event: [String: Any] = ["type": "stroke_point", "id": id, "x": x, "y": y]
        applyEvent(event, senderId: myId)
        send(event, reliable: true)
    }

    func localStrokeEnd(id: String) {
        let event: [String: Any] = ["type": "stroke_end", "id": id]
        applyEvent(event, senderId: myId)
        send(event, reliable: true)
    }

    func localLaser(color: String, x: Double, y: Double, target: String?) {
        var event: [String: Any] = ["type": "laser", "participantId": myId, "color": color, "x": x, "y": y]
        if let target { event["target"] = target }
        applyEvent(event, senderId: myId)
        send(event, reliable: false)
    }

    func localClear(target: String?) {
        var event: [String: Any] = ["type": "clear"]
        if let target { event["target"] = target }
        applyEvent(event, senderId: myId)
        send(event, reliable: true)
    }
}

/// Draws a laser as a tapering, fading streak through its recent points
/// rather than a string of separate dots: the trail reads as one continuous
/// beam, brightest and thickest at the tip where the pointer is now.
///
/// Shared by the in-app tile overlay and the Mac screen overlay so the two
/// can't drift apart.
func drawLaserTrail(
    _ context: inout GraphicsContext,
    laser: AnnotationLaser,
    now: Date,
    rect: CGRect,
    scale: CGFloat = 1
) {
    let live = laser.points.filter { now.timeIntervalSince($0.t) < laserFadeSeconds }
    guard live.count >= 1 else { return }

    let color = ThemeColor(hex: laser.color).color
    let point = { (p: AnnotationPoint) in
        CGPoint(x: rect.minX + p.x * rect.width, y: rect.minY + p.y * rect.height)
    }

    // Each segment is drawn separately so width and opacity can follow the
    // age of the trail; a single stroked path can only carry one of each.
    if live.count >= 2 {
        for i in 1 ..< live.count {
            let age = now.timeIntervalSince(live[i].t)
            let life = max(0, min(1, 1 - age / laserFadeSeconds))
            guard life > 0 else { continue }

            var segment = Path()
            segment.move(to: point(live[i - 1]))
            segment.addLine(to: point(live[i]))

            // Glow first, then a brighter core over it -- two passes is what
            // gives the streak its beam look rather than a flat line.
            context.stroke(
                segment,
                with: .color(color.opacity(0.25 * life)),
                style: StrokeStyle(lineWidth: (10 * life + 3) * scale, lineCap: .round, lineJoin: .round)
            )
            context.stroke(
                segment,
                with: .color(color.opacity(life)),
                style: StrokeStyle(lineWidth: (3 * life + 1.5) * scale, lineCap: .round, lineJoin: .round)
            )
        }
    }

    // The tip: a dot so a stationary pointer is still visible, and so the
    // head of a moving trail reads as the pointer itself.
    if let tip = live.last {
        let life = max(0, min(1, 1 - now.timeIntervalSince(tip.t) / laserFadeSeconds))
        if life > 0 {
            let pt = point(tip)
            let radius = (4 * life + 2) * scale
            context.fill(
                Path(ellipseIn: CGRect(x: pt.x - radius * 2.2, y: pt.y - radius * 2.2,
                                       width: radius * 4.4, height: radius * 4.4)),
                with: .color(color.opacity(0.2 * life))
            )
            context.fill(
                Path(ellipseIn: CGRect(x: pt.x - radius, y: pt.y - radius,
                                       width: radius * 2, height: radius * 2)),
                with: .color(color.opacity(life))
            )
        }
    }
}

struct ScreenShareAnnotationOverlay: View {
    @ObservedObject var controller: AnnotationController
    var videoWidth: CGFloat
    var videoHeight: CGFloat
    /// Identity of whoever is sharing the screen this overlay sits on, so
    /// marks meant for someone else's share aren't drawn here.
    var target: String?
    /// Fires when the capture (screenshot) toolbar button is tapped.
    var onCapture: (() -> Void)?
    /// Greys the capture button out while a save is in flight. Kept separate
    /// from `onCapture` being nil, which hides the button entirely -- doing
    /// that mid-capture would shuffle the whole toolbar under the user's
    /// finger every time they took a screenshot.
    var captureDisabled: Bool = false

    private enum Tool { case none, pen, laser }

    @State private var tool: Tool = .none
    @State private var colorHex: String = annotationColors[0]
    @State private var localStrokeId: String?
    @State private var lastPoint: (x: Double, y: Double)?

    var body: some View {
        GeometryReader { geo in
            let rect = Self.videoContentRect(container: geo.size, videoWidth: videoWidth, videoHeight: videoHeight)

            ZStack(alignment: .top) {
                TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { _ in
                    Canvas { context, _ in
                        for stroke in controller.visibleStrokes(for: target) where stroke.points.count >= 2 {
                            var path = Path()
                            for (i, p) in stroke.points.enumerated() {
                                let pt = CGPoint(x: rect.minX + p.x * rect.width, y: rect.minY + p.y * rect.height)
                                if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                            }
                            context.stroke(
                                path,
                                with: .color(ThemeColor(hex: stroke.color).color),
                                style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
                            )
                        }

                        let now = Date()
                        for laser in controller.visibleLasers(for: target) {
                            drawLaserTrail(&context, laser: laser, now: now, rect: rect)
                        }
                    }
                }
                .allowsHitTesting(tool != .none)
                .contentShape(Rectangle())
                .gesture(dragGesture(rect: rect))

                toolbar
                    .padding(.top, 8)
            }
        }
    }

    private func dragGesture(rect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard tool != .none, rect.width > 0, rect.height > 0 else { return }
                let nx = Double(min(max((value.location.x - rect.minX) / rect.width, 0), 1))
                let ny = Double(min(max((value.location.y - rect.minY) / rect.height, 0), 1))

                if tool == .pen {
                    if let id = localStrokeId {
                        if movedEnough(nx, ny) {
                            controller.localStrokePoint(id: id, x: nx, y: ny)
                            lastPoint = (nx, ny)
                        }
                    } else {
                        let id = "\(controller.myId)-\(Date().timeIntervalSince1970)-\(Int.random(in: 0 ... 9999))"
                        localStrokeId = id
                        lastPoint = (nx, ny)
                        controller.localStrokeStart(id: id, color: colorHex, x: nx, y: ny, target: target)
                    }
                } else if tool == .laser {
                    if movedEnough(nx, ny) {
                        controller.localLaser(color: colorHex, x: nx, y: ny, target: target)
                        lastPoint = (nx, ny)
                    }
                }
            }
            .onEnded { _ in
                if let id = localStrokeId {
                    controller.localStrokeEnd(id: id)
                }
                localStrokeId = nil
                lastPoint = nil
            }
    }

    private func movedEnough(_ nx: Double, _ ny: Double) -> Bool {
        guard let last = lastPoint else { return true }
        return abs(nx - last.x) + abs(ny - last.y) > minPointDistance
    }

    private var toolbar: some View {
        HStack(spacing: 2) {
            toolButton(systemName: "pencil.tip", selected: tool == .pen) {
                tool = tool == .pen ? .none : .pen
            }
            toolButton(systemName: "dot.scope", selected: tool == .laser) {
                tool = tool == .laser ? .none : .laser
            }
            ForEach(annotationColors, id: \.self) { c in
                Circle()
                    .fill(ThemeColor(hex: c).color)
                    .frame(width: 20, height: 20)
                    .overlay(Circle().stroke(Color.white, lineWidth: colorHex == c ? 2 : 0))
                    .padding(.horizontal, 2)
                    .contentShape(Circle())
                    .onTapGesture {
                        colorHex = c
                        if tool == .none { tool = .pen }
                    }
            }
            toolButton(systemName: "trash", selected: false) {
                controller.localClear(target: target)
            }
            if let onCapture {
                toolButton(systemName: "camera", selected: false, action: onCapture)
                    .disabled(captureDisabled)
                    .opacity(captureDisabled ? 0.4 : 1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.black.opacity(0.6)))
    }

    private func toolButton(systemName: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .frame(width: 32, height: 32)
                .background(Circle().fill(selected ? Color.accentColor : Color.clear))
                .foregroundColor(.white)
        }
    }

    /// Cover-fit rect of the video within its container -- matches the web
    /// overlay's `getVideoRect` / Android's `calculateVideoContentRect`.
    static func videoContentRect(container: CGSize, videoWidth: CGFloat, videoHeight: CGFloat) -> CGRect {
        guard container.width > 0, container.height > 0 else {
            return CGRect(origin: .zero, size: container)
        }
        let vw = videoWidth > 0 ? videoWidth : 16
        let vh = videoHeight > 0 ? videoHeight : 9
        let containerAspect = container.width / container.height
        let videoAspect = vw / vh

        if videoAspect > containerAspect {
            let w = container.width
            let h = container.width / videoAspect
            return CGRect(x: 0, y: (container.height - h) / 2, width: w, height: h)
        } else {
            let h = container.height
            let w = container.height * videoAspect
            return CGRect(x: (container.width - w) / 2, y: 0, width: w, height: h)
        }
    }
}
