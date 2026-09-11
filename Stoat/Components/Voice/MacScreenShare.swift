//
//  MacScreenShare.swift
//  Revolt
//
//  Be On It: screen sharing for the Mac Catalyst build.
//
//  The iOS path publishes the screen through a ReplayKit broadcast upload
//  extension, which macOS has no equivalent of -- broadcast extensions are
//  an iOS-only extension point, and a Catalyst app cannot host one. That
//  left the Mac build with no way to present at all.
//
//  ScreenCaptureKit is the Mac's own answer, and Apple annotates it as
//  available to Catalyst (`API_AVAILABLE(macos(12.3), macCatalyst(18.2))`),
//  so this captures with SCStream and hands the frames to LiveKit through
//  BufferCapturer -- the same public "here are my own frames" entry point
//  its camera and buffer tracks use. Nothing here needs an App Group, a
//  second process, or a paid team: it is all in-process, gated only by the
//  system's Screen Recording permission.
//

#if targetEnvironment(macCatalyst)

import Foundation
import LiveKit
import ScreenCaptureKit

/// Captures a display with ScreenCaptureKit and publishes it as this
/// participant's screen-share track.
@available(macCatalyst 18.2, *)
final class MacScreenShareCapturer: NSObject, SCStreamOutput, SCStreamDelegate {
    /// Matches the iOS side's framing: LiveKit treats `.screenShareVideo`
    /// specially (content hint, simulcast layers), so the track has to be
    /// created with that source rather than a plain video track.
    private var stream: SCStream?
    private var track: LocalVideoTrack?
    private var publication: LocalTrackPublication?
    private var capturer: BufferCapturer?

    /// Frames arrive on this queue rather than the main one; SCStream
    /// delivers at the display's refresh rate and compositing the main
    /// thread into that path would stutter the UI.
    private let outputQueue = DispatchQueue(label: "chat.stoat.macscreenshare")

    private(set) var isSharing = false

    /// - Returns: the publication, so the caller can unpublish it the same
    ///   way it would any other local track.
    @discardableResult
    func start(in room: Room) async throws -> LocalTrackPublication {
        stop()

        // Excluding our own app keeps the shared view from recursing into
        // the window that's displaying it.
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let display = content.displays.first else {
            throw MacScreenShareError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.width = display.width
        config.height = display.height
        // BGRA is what LiveKit's buffer path wants; asking SCStream for it
        // avoids a conversion on every frame.
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 5
        config.showsCursor = true

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        try await stream.startCapture()
        self.stream = stream

        let track = LocalVideoTrack.createBufferTrack(
            name: Track.screenShareVideoName,
            source: .screenShareVideo,
            options: BufferCaptureOptions(
                dimensions: Dimensions(width: Int32(display.width), height: Int32(display.height)),
                fps: 30
            )
        )
        capturer = track.capturer as? BufferCapturer
        self.track = track

        let publication = try await room.localParticipant.publish(videoTrack: track)
        self.publication = publication
        isSharing = true
        return publication
    }

    func stop() {
        isSharing = false
        if let stream {
            // Fire-and-forget: the caller is usually already tearing the
            // call down and there is nothing useful to do with a failure
            // to stop a stream we're dropping anyway.
            Task { try? await stream.stopCapture() }
        }
        stream = nil
        capturer = nil
        track = nil
        publication = nil
    }

    func stopAndUnpublish(from room: Room) async {
        let publication = self.publication
        stop()
        if let publication {
            try? await room.localParticipant.unpublish(publication: publication)
        }
    }

    // MARK: SCStreamOutput

    func stream(_: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        // SCStream emits frames even when nothing on screen changed, and
        // marks those incomplete; forwarding them would publish blank
        // buffers whenever the display is idle.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete
        else { return }

        capturer?.capture(sampleBuffer)
    }

    // MARK: SCStreamDelegate

    func stream(_: SCStream, didStopWithError _: Error) {
        // The system stops the stream when the user revokes Screen
        // Recording or the display goes away.
        stop()
    }
}

/// The capturer needs macCatalyst 18.2 (ScreenCaptureKit's availability)
/// while the app deploys to 18.0, and a stored property can't carry an
/// availability annotation -- so the view holds this instead and reaches
/// the capturer through a gated accessor.
final class MacScreenShareHolder {
    private var storage: Any?

    @available(macCatalyst 18.2, *)
    var capturer: MacScreenShareCapturer {
        if let existing = storage as? MacScreenShareCapturer { return existing }
        let created = MacScreenShareCapturer()
        storage = created
        return created
    }
}

enum MacScreenShareError: LocalizedError {
    case noDisplay
    case unsupported

    var errorDescription: String? {
        switch self {
        case .noDisplay: "No display available to share."
        case .unsupported: "Screen sharing on Mac needs macOS 15.2 or later."
        }
    }
}

#endif
