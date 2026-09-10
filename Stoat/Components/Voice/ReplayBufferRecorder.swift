//
//  ReplayBufferRecorder.swift
//  Revolt
//
//  Be On It: rolling "instant replay" buffer for the local screen share,
//  mirroring desktop/web/Android's "save last N seconds" feature.
//
//  Desktop shells out to a bundled ffmpeg binary; the browser build uses
//  ffmpeg.wasm; Android uses MediaCodec/MediaMuxer directly (no ffmpeg
//  library is available there). iOS has no ffmpeg wrapper either, so this
//  uses the platform's own AVFoundation instead: LiveKit delivers local
//  screen-share frames as CVPixelBuffer (via the VideoRenderer protocol),
//  which AVAssetWriter can record directly with no colour-space conversion
//  needed at all -- simpler than every other platform's pipeline.
//
//  Design: same rolling-segment approach as desktop/web -- AVAssetWriter
//  can't be asked for "the last N seconds" of an in-progress recording, so
//  this restarts the writer every SEGMENT_SECONDS, producing a rolling set
//  of short, independently-complete .mov segments. Saving a clip hands the
//  segments covering at least the requested duration to AVMutableComposition
//  + AVAssetExportSession to concatenate and trim -- no re-encode needed
//  since export can pass through the source format for a plain trim/concat.
//
//  All encoder state is confined to one serial queue (`queue`); the
//  VideoRenderer callback and the public start/stop/saveReplay/capture
//  entry points may be called from any thread/actor.
//

import AVFoundation
import Foundation
import LiveKit
import Photos
#if canImport(UIKit)
import UIKit
#endif

final class ReplayBufferRecorder: NSObject, VideoRenderer, ObservableObject {
    static let segmentSeconds: TimeInterval = 5
    /// Longest clip the UI offers (see the duration menu in VoiceChannelView)
    /// -- bounds how much footage the buffer needs to retain.
    static let maxClipSeconds: TimeInterval = 120
    static let maxSegments = Int((maxClipSeconds / segmentSeconds).rounded(.up)) + 2
    /// Screen-share content rarely needs full frame rate to be useful as a
    /// "what just happened" reference, and a lower rate keeps CPU/battery/
    /// buffer-memory cost down for something that runs the whole call.
    static let targetFPS: Double = 10
    static let bitrate = 3_000_000

    // MARK: VideoRenderer

    var isAdaptiveStreamEnabled: Bool { false }
    var adaptiveStreamSize: CGSize { .zero }

    /// Drives visibility of the "save replay" toolbar entry.
    @Published private(set) var isAvailable = false

    // MARK: State (all queue-confined below this point)

    private let queue = DispatchQueue(label: "chat.stoat.replaybuffer")
    private weak var track: VideoTrack?

    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var pixelAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var sessionStarted = false
    private var currentSegmentURL: URL?
    private var segmentDeadline: CFAbsoluteTime = 0
    private var segmentURLs: [URL] = []
    private var lastFeedTime: CFAbsoluteTime = 0
    private var latestPixelBuffer: CVPixelBuffer?

    // MARK: Lifecycle

    func start(track: VideoTrack) {
        track.add(videoRenderer: self)
        self.track = track
        isAvailable = true
        queue.async { [weak self] in
            self?.stopLocked()
            self?.startSegmentLocked()
        }
    }

    func stop() {
        if let track { track.remove(videoRenderer: self) }
        track = nil
        isAvailable = false
        queue.async { [weak self] in
            self?.stopLocked()
        }
    }

    private func stopLocked() {
        finishWriterSynchronously()
        if let url = currentSegmentURL { try? FileManager.default.removeItem(at: url) }
        currentSegmentURL = nil
        for url in segmentURLs { try? FileManager.default.removeItem(at: url) }
        segmentURLs = []
        latestPixelBuffer = nil
    }

    private func startSegmentLocked() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("beonit-replay-\(UUID().uuidString).mov")
        currentSegmentURL = url
        writer = try? AVAssetWriter(outputURL: url, fileType: .mov)
        writerInput = nil
        pixelAdaptor = nil
        sessionStarted = false
        segmentDeadline = CFAbsoluteTimeGetCurrent() + Self.segmentSeconds
    }

    /// Finishes the writer currently open (if any), blocking this queue
    /// until it's done -- `finishWriting`'s completion isn't guaranteed to
    /// land back on this queue, so a semaphore is the simplest way to keep
    /// segment rollover synchronous with frame delivery.
    @discardableResult
    private func finishWriterSynchronously() -> Bool {
        guard let writer, sessionStarted else {
            self.writer = nil
            writerInput = nil
            pixelAdaptor = nil
            return false
        }
        writerInput?.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        let completed = writer.status == .completed
        self.writer = nil
        writerInput = nil
        pixelAdaptor = nil
        sessionStarted = false
        return completed
    }

    private func rolloverSegmentLocked() {
        let completed = finishWriterSynchronously()
        if completed, let url = currentSegmentURL {
            segmentURLs.append(url)
            if segmentURLs.count > Self.maxSegments {
                let removed = segmentURLs.removeFirst()
                try? FileManager.default.removeItem(at: removed)
            }
        } else if let url = currentSegmentURL {
            try? FileManager.default.removeItem(at: url)
        }
        startSegmentLocked()
    }

    // MARK: VideoRenderer callback

    func render(frame: LiveKit.VideoFrame) {
        guard let pixelBuffer = (frame.buffer as? CVPixelVideoBuffer)?.pixelBuffer else { return }
        let timestamp = CMTime(value: frame.timeStampNs, timescale: 1_000_000_000)
        queue.async { [weak self] in
            self?.appendLocked(pixelBuffer: pixelBuffer, timestamp: timestamp)
        }
    }

    private func appendLocked(pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastFeedTime >= 1.0 / Self.targetFPS else { return }
        lastFeedTime = now
        latestPixelBuffer = pixelBuffer

        guard writer != nil else { return }

        if CFAbsoluteTimeGetCurrent() >= segmentDeadline {
            rolloverSegmentLocked()
        }
        guard let writer else { return }

        if writerInput == nil {
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: Self.bitrate,
                ],
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { return }
            writer.add(input)
            writerInput = input
            pixelAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        }

        if !sessionStarted {
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: timestamp)
            sessionStarted = true
        }

        guard let writerInput, writerInput.isReadyForMoreMediaData else { return }
        pixelAdaptor?.append(pixelBuffer, withPresentationTime: timestamp)
    }

    // MARK: Screenshot capture

    /// Latest buffered frame, for the annotation toolbar's capture button.
    /// Only available while the buffer is running (i.e. while screen
    /// sharing), same as on the other platforms.
    func captureLatestFrame(completion: @escaping (CVPixelBuffer?) -> Void) {
        queue.async { [weak self] in
            let buffer = self?.latestPixelBuffer
            DispatchQueue.main.async { completion(buffer) }
        }
    }

    // MARK: Save

    func saveReplay(seconds: TimeInterval, completion: @escaping (Bool) -> Void) {
        queue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion(false) }
                return
            }

            // Finalize whatever's currently recording first, so the clip
            // includes up to "right now" instead of missing up to
            // segmentSeconds of it, then immediately resume recording.
            let completedCurrent = self.finishWriterSynchronously()
            if completedCurrent, let url = self.currentSegmentURL {
                self.segmentURLs.append(url)
                if self.segmentURLs.count > Self.maxSegments {
                    let removed = self.segmentURLs.removeFirst()
                    try? FileManager.default.removeItem(at: removed)
                }
            } else if let url = self.currentSegmentURL {
                try? FileManager.default.removeItem(at: url)
            }
            self.startSegmentLocked()

            // Snapshot for export -- these files remain part of the live
            // rolling buffer afterward (subject to the normal maxSegments
            // eviction), they are not consumed or deleted by a save.
            let segments = self.segmentURLs

            guard !segments.isEmpty else {
                DispatchQueue.main.async { completion(false) }
                return
            }

            let clipSeconds = min(max(seconds, 1), Self.maxClipSeconds)
            Self.exportClip(segments: segments, clipSeconds: clipSeconds) { success in
                DispatchQueue.main.async { completion(success) }
            }
        }
    }

    private static func exportClip(segments: [URL], clipSeconds: TimeInterval, completion: @escaping (Bool) -> Void) {
        Task {
            let composition = AVMutableComposition()
            guard let compositionTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else {
                completion(false)
                return
            }

            for url in segments {
                let asset = AVURLAsset(url: url)
                guard let assetTrack = try? await asset.loadTracks(withMediaType: .video).first,
                      let duration = try? await asset.load(.duration)
                else { continue }
                let range = CMTimeRange(start: .zero, duration: duration)
                try? compositionTrack.insertTimeRange(range, of: assetTrack, at: composition.duration)
            }

            guard composition.duration.seconds > 0 else {
                completion(false)
                return
            }

            let clipDuration = CMTime(seconds: clipSeconds, preferredTimescale: 600)
            // Trims to "at least the last clipSeconds" -- exporting can only
            // start at a keyframe boundary internally, same "a few seconds
            // over, never under" characteristic as the ffmpeg-based trim on
            // the other platforms.
            let start = max(CMTime.zero, composition.duration - clipDuration)
            let trimRange = CMTimeRange(start: start, end: composition.duration)

            guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
                completion(false)
                return
            }
            let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("beonit-clip-\(UUID().uuidString).mov")
            export.outputURL = outputURL
            export.outputFileType = .mov
            export.timeRange = trimRange

            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                export.exportAsynchronously { cont.resume() }
            }

            guard export.status == .completed else {
                try? FileManager.default.removeItem(at: outputURL)
                completion(false)
                return
            }

            let saved = await saveVideoToPhotos(url: outputURL)
            try? FileManager.default.removeItem(at: outputURL)
            completion(saved)
        }
    }

    private static func saveVideoToPhotos(url: URL) async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return false }
        return await withCheckedContinuation { cont in
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }) { success, _ in
                cont.resume(returning: success)
            }
        }
    }
}

#if canImport(UIKit)
/// Composite the raw pixel buffer with the strokes/lasers currently drawn
/// on top of it (i.e. exactly what's visible right now) into a UIImage, at
/// the video's native pixel size. Mirrors the web/Android capture -- draws
/// directly with Core Graphics rather than re-rendering the SwiftUI
/// overlay, so the result is pixel-accurate to the buffer regardless of
/// how the on-screen tile happens to be scaled.
enum AnnotationScreenshot {
    static func composite(pixelBuffer: CVPixelBuffer, strokes: [AnnotationStroke], lasers: [String: AnnotationLaser]) -> UIImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let ciContext = CIContext()
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return nil }

        let width = cgImage.width
        let height = cgImage.height
        let size = CGSize(width: width, height: height)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        return renderer.image { rendererContext in
            let cg = rendererContext.cgContext
            cg.draw(cgImage, in: CGRect(origin: .zero, size: size))

            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            cg.setLineWidth(CGFloat(width) / 400)
            for stroke in strokes where stroke.points.count >= 2 {
                cg.beginPath()
                for (i, p) in stroke.points.enumerated() {
                    let pt = CGPoint(x: p.x * Double(width), y: p.y * Double(height))
                    if i == 0 { cg.move(to: pt) } else { cg.addLine(to: pt) }
                }
                cg.setStrokeColor(themeCGColor(hex: stroke.color))
                cg.strokePath()
            }

            let now = Date()
            for (_, laser) in lasers {
                for p in laser.points {
                    let age = now.timeIntervalSince(p.t)
                    guard age < laserFadeSeconds else { continue }
                    let alpha = max(0, min(1, 1 - age / laserFadeSeconds))
                    let radius = (5 * alpha + 3) * (Double(width) / 1000)
                    let pt = CGPoint(x: p.x * Double(width), y: p.y * Double(height))
                    cg.setFillColor(themeCGColor(hex: laser.color, alpha: alpha))
                    cg.fillEllipse(in: CGRect(x: pt.x - radius, y: pt.y - radius, width: radius * 2, height: radius * 2))
                }
            }
        }
    }

    private static func themeCGColor(hex: String, alpha: Double = 1) -> CGColor {
        let c = ThemeColor(hex: hex)
        return CGColor(red: c.r, green: c.g, blue: c.b, alpha: c.a * alpha)
    }

    static func save(_ image: UIImage) async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return false }
        return await withCheckedContinuation { cont in
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }) { success, _ in
                cont.resume(returning: success)
            }
        }
    }
}
#endif
