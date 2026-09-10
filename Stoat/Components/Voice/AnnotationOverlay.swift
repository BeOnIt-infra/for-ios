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
    let color: String
    var points: [AnnotationPoint]
    /// Set once stroke_end arrives; finished strokes accept no more points.
    var done: Bool = false
}

struct AnnotationLaser {
    var color: String
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
    @Published private(set) var lasers: [String: AnnotationLaser] = [:]

    var myId: String = ""
    /// Set by the room delegate wiring; publishes to LiveKit's data channel.
    var onSend: ((_ payload: [String: Any], _ reliable: Bool) -> Void)?

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
                id: id, author: senderId, color: color,
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
            var laser = lasers[senderId] ?? AnnotationLaser(color: color, points: [])
            laser.color = color
            laser.points = laser.points.filter { Date().timeIntervalSince($0.t) < laserFadeSeconds }
            laser.points.append(AnnotationPoint(x: x, y: y, t: Date()))
            lasers[senderId] = laser

        // Scoped to the sender's own strokes: everyone in the call may
        // publish on this topic, so a global wipe would let anyone erase
        // other people's annotations.
        case "clear":
            strokes = strokes.filter { $0.author != senderId }

        default: break
        }
    }

    private func send(_ payload: [String: Any], reliable: Bool) {
        onSend?(payload, reliable)
    }

    func localStrokeStart(id: String, color: String, x: Double, y: Double) {
        let event: [String: Any] = ["type": "stroke_start", "id": id, "color": color, "x": x, "y": y]
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

    func localLaser(color: String, x: Double, y: Double) {
        let event: [String: Any] = ["type": "laser", "participantId": myId, "color": color, "x": x, "y": y]
        applyEvent(event, senderId: myId)
        send(event, reliable: false)
    }

    func localClear() {
        let event: [String: Any] = ["type": "clear"]
        applyEvent(event, senderId: myId)
        send(event, reliable: true)
    }
}

struct ScreenShareAnnotationOverlay: View {
    @ObservedObject var controller: AnnotationController
    var videoWidth: CGFloat
    var videoHeight: CGFloat
    /// Fires when the capture (screenshot) toolbar button is tapped.
    var onCapture: (() -> Void)?

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
                        for stroke in controller.strokes where stroke.points.count >= 2 {
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
                        for (_, laser) in controller.lasers {
                            for p in laser.points {
                                let age = now.timeIntervalSince(p.t)
                                guard age < laserFadeSeconds else { continue }
                                let alpha = max(0, min(1, 1 - age / laserFadeSeconds))
                                let radius = 5 * alpha + 3
                                let pt = CGPoint(x: rect.minX + p.x * rect.width, y: rect.minY + p.y * rect.height)
                                context.fill(
                                    Path(ellipseIn: CGRect(x: pt.x - radius, y: pt.y - radius, width: radius * 2, height: radius * 2)),
                                    with: .color(ThemeColor(hex: laser.color).color.opacity(alpha))
                                )
                            }
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
                        controller.localStrokeStart(id: id, color: colorHex, x: nx, y: ny)
                    }
                } else if tool == .laser {
                    if movedEnough(nx, ny) {
                        controller.localLaser(color: colorHex, x: nx, y: ny)
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
                controller.localClear()
            }
            if let onCapture {
                toolButton(systemName: "camera", selected: false, action: onCapture)
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
