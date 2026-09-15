//
//  ScreenShareTile.swift
//  Revolt
//
//  Renders a screen-share video track with the drawing/laser annotation
//  overlay on top, plus a capture (screenshot) button in its toolbar.
//
//  Screenshot capture works for any screen-share tile being viewed --
//  local or a remote participant's -- each tile keeps its own latest
//  decoded frame (LatestFrameHolder) so the capture composites whatever
//  this viewer is actually seeing, matching the web/Android capture
//  button (which reads the local <video>/ImageReader frame the same way
//  regardless of whether the share is local or remote).
//

import LiveKit
import LiveKitComponents
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Caches the most recently rendered frame of a video track for on-demand
/// capture. Lightweight by design -- unlike ReplayBufferRecorder this does
/// no encoding or buffering, just keeps the latest CVPixelBuffer around.
final class LatestFrameHolder: NSObject, VideoRenderer {
    var isAdaptiveStreamEnabled: Bool { false }
    var adaptiveStreamSize: CGSize { .zero }

    /// The buffers WebRTC hands `render(frame:)` come from a recycling pool
    /// and get overwritten once the callback returns, so the retained frame
    /// has to be our own copy or a capture would composite whatever the
    /// decoder happened to write into it since. Copying every frame is far
    /// more memcpy than a screenshot button needs, hence the sampling --
    /// the captured frame is at most this far behind live.
    private static let sampleInterval: CFAbsoluteTime = 1.0 / 4.0

    private let queue = DispatchQueue(label: "chat.stoat.latestframe")
    private var latest: CVPixelBuffer?
    private var lastSampleTime: CFAbsoluteTime = 0
    private weak var track: VideoTrack?

    func attach(to track: VideoTrack) {
        detach()
        track.add(videoRenderer: self)
        self.track = track
    }

    func detach() {
        if let track { track.remove(videoRenderer: self) }
        track = nil
        queue.async { [weak self] in self?.latest = nil }
    }

    func render(frame: LiveKit.VideoFrame) {
        guard let pixelBuffer = (frame.buffer as? CVPixelVideoBuffer)?.pixelBuffer else { return }
        let now = CFAbsoluteTimeGetCurrent()
        // Sampled on the delivery thread, and copied there too: by the time
        // a `queue.async` block ran the pool could already have reused it.
        guard now - lastSampleTime >= Self.sampleInterval else { return }
        lastSampleTime = now
        guard let copy = Self.deepCopy(pixelBuffer) else { return }
        queue.async { [weak self] in self?.latest = copy }
    }

    private static func deepCopy(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        var created: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            CVPixelBufferGetWidth(source),
            CVPixelBufferGetHeight(source),
            CVPixelBufferGetPixelFormatType(source),
            attributes as CFDictionary,
            &created
        ) == kCVReturnSuccess, let destination = created else { return nil }

        guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard CVPixelBufferLockBaseAddress(destination, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }

        let planeCount = CVPixelBufferGetPlaneCount(source)
        if planeCount == 0 {
            guard let from = CVPixelBufferGetBaseAddress(source),
                  let to = CVPixelBufferGetBaseAddress(destination) else { return nil }
            let fromStride = CVPixelBufferGetBytesPerRow(source)
            let toStride = CVPixelBufferGetBytesPerRow(destination)
            let rowBytes = min(fromStride, toStride)
            for row in 0 ..< CVPixelBufferGetHeight(source) {
                memcpy(to + row * toStride, from + row * fromStride, rowBytes)
            }
        } else {
            for plane in 0 ..< planeCount {
                guard let from = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                      let to = CVPixelBufferGetBaseAddressOfPlane(destination, plane) else { return nil }
                let fromStride = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
                let toStride = CVPixelBufferGetBytesPerRowOfPlane(destination, plane)
                let rowBytes = min(fromStride, toStride)
                for row in 0 ..< CVPixelBufferGetHeightOfPlane(source, plane) {
                    memcpy(to + row * toStride, from + row * fromStride, rowBytes)
                }
            }
        }
        return destination
    }

    func capture(completion: @escaping (CVPixelBuffer?) -> Void) {
        queue.async { [weak self] in
            let buffer = self?.latest
            DispatchQueue.main.async { completion(buffer) }
        }
    }
}

struct ScreenShareTile: View {
    let videoTrack: VideoTrack
    /// Identity of the participant whose screen this tile shows.
    let sharerIdentity: String?
    @ObservedObject var annotationController: AnnotationController

    @State private var frameHolder = LatestFrameHolder()
    @State private var isCapturing = false
    // One replay buffer per tile, so a viewer can save the last N seconds of
    // any share they're watching -- not only their own. Buffers whatever
    // track this tile shows (local or remote).
    @StateObject private var replay = ReplayBufferRecorder()
    @State private var replayAlert: String?

    var body: some View {
        ZStack {
            SwiftUIVideoView(videoTrack, layoutMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            ScreenShareAnnotationOverlay(
                controller: annotationController,
                videoWidth: CGFloat(videoTrack.dimensions?.width ?? 0),
                videoHeight: CGFloat(videoTrack.dimensions?.height ?? 0),
                // Whose share this tile is showing: marks are scoped to it, so
                // two people sharing at once no longer share one canvas.
                target: sharerIdentity,
                onCapture: handleCapture,
                onSaveReplay: handleSaveReplay,
                captureDisabled: isCapturing
            )
        }
        .alert(replayAlert ?? "", isPresented: Binding(
            get: { replayAlert != nil },
            set: { if !$0 { replayAlert = nil } }
        )) { Button("OK", role: .cancel) {} }
        .onAppear { frameHolder.attach(to: videoTrack); replay.start(track: videoTrack) }
        // A participant republishing their share swaps the track under a
        // tile that never disappeared, so onAppear alone would leave the
        // holder feeding off the old, now-dead one.
        .onChange(of: ObjectIdentifier(videoTrack)) { _, _ in
            frameHolder.attach(to: videoTrack)
            replay.start(track: videoTrack)
        }
        .onDisappear { frameHolder.detach(); replay.stop() }
    }

    private func handleSaveReplay(seconds: Int) {
        replay.saveReplay(seconds: TimeInterval(seconds)) { url in
            replayAlert = url != nil ? "Clip saved" : "Couldn't save clip"
        }
    }

    private func handleCapture() {
        #if canImport(UIKit)
        guard !isCapturing else { return }
        isCapturing = true
        let strokes = annotationController.visibleStrokes(for: sharerIdentity)
        let lasers = annotationController.visibleLasers(for: sharerIdentity)
        frameHolder.capture { pixelBuffer in
            guard let pixelBuffer else {
                isCapturing = false
                return
            }
            Task.detached(priority: .userInitiated) {
                if let image = AnnotationScreenshot.composite(pixelBuffer: pixelBuffer, strokes: strokes, lasers: lasers) {
                    _ = await AnnotationScreenshot.save(image)
                }
                await MainActor.run { isCapturing = false }
            }
        }
        #endif
    }
}
