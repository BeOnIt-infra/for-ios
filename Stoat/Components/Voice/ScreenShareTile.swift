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

    private let queue = DispatchQueue(label: "chat.stoat.latestframe")
    private var latest: CVPixelBuffer?
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
        queue.async { [weak self] in self?.latest = pixelBuffer }
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
    @ObservedObject var annotationController: AnnotationController

    @State private var frameHolder = LatestFrameHolder()
    @State private var isCapturing = false

    var body: some View {
        ZStack {
            SwiftUIVideoView(videoTrack, layoutMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            ScreenShareAnnotationOverlay(
                controller: annotationController,
                videoWidth: CGFloat(videoTrack.dimensions?.width ?? 0),
                videoHeight: CGFloat(videoTrack.dimensions?.height ?? 0),
                onCapture: isCapturing ? nil : handleCapture
            )
        }
        .onAppear { frameHolder.attach(to: videoTrack) }
        .onDisappear { frameHolder.detach() }
    }

    private func handleCapture() {
        #if canImport(UIKit)
        guard !isCapturing else { return }
        isCapturing = true
        let strokes = annotationController.strokes
        let lasers = annotationController.lasers
        frameHolder.capture { pixelBuffer in
            guard let pixelBuffer else {
                isCapturing = false
                return
            }
            Task.detached(priority: .userInitiated) {
                let image = AnnotationScreenshot.composite(pixelBuffer: pixelBuffer, strokes: strokes, lasers: lasers)
                _ = await image.map { await AnnotationScreenshot.save($0) }
                await MainActor.run { isCapturing = false }
            }
        }
        #endif
    }
}
