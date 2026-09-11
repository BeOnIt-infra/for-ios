//
//  VoiceChannelView.swift
//  Revolt
//
//  Created by Angelo on 29/03/2024.
//

import Foundation
import SwiftUI
import LiveKit
import Types
import ActivityKit
import AVKit
import LiveKitComponents

private func downloadImage(from url: URL) async throws -> URL? {
    guard var destination = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: "group.xyz.beonit.app")
    else { return nil }
    
    destination = destination.appendingPathComponent(url.lastPathComponent)
    
    guard !FileManager.default.fileExists(atPath: destination.path()) else {
        return destination
    }
    
    let (source, _) = try await URLSession.shared.download(from: url)
    try FileManager.default.moveItem(at: source, to: destination)
    return destination
}


struct TokenResponse: Decodable {
    var token: String
}

struct VoiceChannelView: View {
    @EnvironmentObject var viewState: ViewState
    
    var channel: Channel
    var server: Server?
    
    var toggleSidebar: () -> ()
    
    @Binding var disableScroll: Bool
    @Binding var disableSidebar: Bool

    @State var unmuted: Bool = false
    @State var defeaned: Bool = false
    @State var screenSharing: Bool = false
    @State var inCall: Bool = false
    @State var updater: Bool = false

    @StateObject private var annotationController = AnnotationController()
    @StateObject private var replayRecorder = ReplayBufferRecorder()
    @State private var showReplayMenu = false

    /// `BroadcastManager.isBroadcastingPublisher` is computed -- it calls
    /// eraseToAnyPublisher() and hands back a fresh AnyPublisher every time
    /// it's read. Reading it inline in the body gave onReceive a different
    /// publisher on every pass, so SwiftUI resubscribed, the subject
    /// replayed, the closure ran, and the view invalidated again: a render
    /// loop that pinned a core at 100%. Held in @State so the identity is
    /// stable for the life of the view.
    @State private var broadcastPublisher = BroadcastManager.shared.isBroadcastingPublisher

    /// Presets offered in the instant-replay duration menu, in seconds.
    /// Kept in sync with ReplayBufferRecorder.maxClipSeconds (the longest
    /// preset here bounds how much footage that buffer needs to retain).
    private static let replayDurations: [Int] = [15, 30, 60, 120]

    @State private var callAlertMessage: String?

    /// Strong reference to the room delegate; see connect().
    @State private var roomDelegate: VoiceChannelDelegate?

    /// Why the broadcast picker would do nothing if we asked for it, or nil
    /// when presenting should work.
    private var screenShareUnavailableReason: String? {
        #if targetEnvironment(simulator)
        // ReplayKit.framework ships in the simulator runtime, so this all
        // compiles and RPSystemBroadcastPickerView instantiates happily --
        // but replayd, the daemon that actually hosts broadcast extensions,
        // is not in the runtime at all. The picker has nothing behind it.
        return "Screen sharing needs a real device. The Simulator has no ReplayKit broadcast service."
        #else
        // False when the app group container is missing (an unsigned build,
        // or entitlements without the App Groups capability) or when
        // RTCScreenSharingExtension isn't set -- either way LiveKit can't
        // reach the extension over its shared-container socket.
        guard !ScreenShareCaptureOptions.defaultToBroadcastExtension else { return nil }
        return "Screen sharing isn't set up in this build: the broadcast extension or its App Group is missing."
        #endif
    }

    #if targetEnvironment(macCatalyst)
    /// Held for the life of the view: the capturer owns the SCStream and the
    /// published track, so losing it mid-share would strand both.
    @State private var macScreenShare = MacScreenShareHolder()

    private func toggleMacScreenShare() {
        guard #available(macCatalyst 18.2, *) else {
            callAlertMessage = MacScreenShareError.unsupported.errorDescription
            return
        }
        guard let room = viewState.currentVoice else { return }
        let capturer = macScreenShare.capturer

        if screenSharing {
            Task {
                await capturer.stopAndUnpublish(from: room)
                screenSharing = false
                replayRecorder.stop()
            }
        } else {
            Task {
                do {
                    try await capturer.start(in: room)
                    screenSharing = true
                    // The on-screen overlay is not opened yet: its window
                    // still comes up opaque with a title bar instead of a
                    // transparent click-through layer, which covers the
                    // screen being shared. Strokes are visible on the tile
                    // in the app meanwhile. See MacAnnotationOverlay.swift.
                } catch {
                    // Denying Screen Recording surfaces here as a
                    // ScreenCaptureKit error rather than a permission
                    // callback, so report whatever it says.
                    callAlertMessage = error.localizedDescription
                    screenSharing = false
                }
            }
        }
    }
    #endif

    private func saveReplay(seconds: Int) {
        replayRecorder.saveReplay(seconds: TimeInterval(seconds)) { success in
            callAlertMessage = success ? "Clip saved" : "Couldn't save clip"
        }
    }

    @MainActor
    func connect() async {
        let node = viewState.apiInfo!.features.livekit.nodes.first!

        let token = try! await viewState.http.joinVoiceChannel(channel: channel.id, node: node.name).get()
        let dele = VoiceChannelDelegate(updater: $updater, annotationController: annotationController, replayRecorder: replayRecorder)
        // Room keeps delegates in an NSHashTable of weak references, so a
        // delegate that only lives in a local is deallocated the moment
        // connect() returns and every callback silently stops: no incoming
        // annotations, no replay buffer start/stop. Hold it for the view's
        // lifetime.
        roomDelegate = dele
        let room = Room(delegate: dele, connectOptions: ConnectOptions(autoSubscribe: false))

        try! await room.connect(url: node.public_url, token: token.token)

        viewState.currentVoiceChannel = channel.id
        viewState.currentVoice = room

        annotationController.myId = room.localParticipant.identity?.stringValue ?? ""
        annotationController.onSend = { [weak room] payload, reliable in
            guard let room, let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
            Task {
                try? await room.localParticipant.publish(
                    data: data,
                    options: DataPublishOptions(topic: "annotate", reliable: reliable)
                )
            }
        }
        
//        let pfp = URL(string: viewState.currentUser!.avatar != nil ? viewState.formatUrl(with: viewState.currentUser!.avatar!) : "\(viewState.http.baseURL)/users/\(viewState.currentUser!.id)/default_avatar")!;
        
        //        activity = try! Activity.request(
        //            attributes: VoiceWidgetAttributes(
        //                us: viewState.currentUser!,
        //                pfp: pfp,
        //                channel: channel,
        //                channelName: channel.getName(viewState)
        //            ),
        //            content: .init(state: VoiceWidgetAttributes.ContentState(currentlySpeaking: [], weSpeaking: false), staleDate: nil)
        //        )
    }
    
    @MainActor
    func disconnect() async {
        if let room = viewState.currentVoice {
            viewState.currentVoice = nil
            viewState.currentVoiceChannel = nil

            if screenSharing {
                #if targetEnvironment(macCatalyst)
                if #available(macCatalyst 18.2, *) {
                    // Leaving the call has to tear the SCStream down too,
                    // or the screen keeps being captured after the room is
                    // gone -- with the system recording indicator still lit.
                    await macScreenShare.capturer.stopAndUnpublish(from: room)
                }
                #else
                BroadcastManager.shared.requestStop()
                #endif
                screenSharing = false
            }
            replayRecorder.stop()
            annotationController.onSend = nil

            await room.disconnect()
            roomDelegate = nil
        }
    }
    
    func partipants(room: Room) -> [(Participant, UserMaybeMember)] {
        return room.allParticipants.values
            .compactMap({ participant in
                if let identity = participant.identity?.stringValue {
                    if let user = viewState.users[identity] {
                        return (participant, user)
                    } else if let metadata = participant.metadata?.data(using: .utf8), let user = try? JSONDecoder().decode(User.self, from: metadata) {
                        viewState.users[user.id] = user
                        
                        return (participant, user)
                    } else {
                        return nil
                    }
                }
                
                return nil
            })
            .map({ (p, user) in
                let member = server.flatMap { server in
                    if let member = viewState.members[server.id]?[user.id] {
                        return member as Member?
                    } else {
                        Task {
                            if let member = try? await viewState.http.fetchMember(server: server.id, member: user.id).get() {
                                viewState.members[server.id]?[user.id] = member
                            }
                        }
                        
                        return nil
                    }
                }
                
                return (p, UserMaybeMember(user: user, member: member))
            })
            .sorted(by: { p1, p2 in
                if p1.0 is LocalParticipant { return true }
                if p2.0 is LocalParticipant { return false }
                return (p1.0.joinedAt ?? Date()) < (p2.0.joinedAt ?? Date())
            })
    }
    
    var body: some View {
        VStack(spacing: 0) {
            PageToolbar(toggleSidebar: toggleSidebar) {
                NavigationLink(value: NavigationDestination.channel_info(channel.id)) {
                    ChannelIcon(channel: channel)
                    Image(systemName: "chevron.right")
                        .frame(height: 4)
                }
            }
            
            VStack {
                ScrollView {
                    if let room = viewState.currentVoice {
                        RoomScope(room: room) {
                            ForEach(partipants(room: room), id: \.1.id) { (participant, user) in
                                let title = user.member?.nickname ?? user.user.display_name ?? user.user.username
                                
                                ForEach(participant.trackPublications.values.filter({ $0.kind == .video })) { track in
                                    VoiceChannelBox(title: title) {
                                        let _ = print(track.source, track.kind, track.isSubscribed)
                                        if track is LocalTrackPublication || track.isSubscribed {
                                            let videoTrack = track.track as! VideoTrack
                                            if track.source == .screenShareVideo {
                                                ScreenShareTile(videoTrack: videoTrack, annotationController: annotationController)
                                            } else {
                                                SwiftUIVideoView(videoTrack, layoutMode: .fit)
                                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                            }
                                        } else if let remoteTrack = track as? RemoteTrackPublication {
                                            ZStack {
                                                viewState.theme.background3
                                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                                
                                                Button {
                                                    Task {
                                                        try! await remoteTrack.set(subscribed: true)
                                                    }
                                                } label: {
                                                    Text("Watch")
                                                        .padding(12)
                                                        .background(Capsule().fill(viewState.theme.background2))
                                                }
                                            }
                                        }
                                    } overlay: {
                                        if let remoteTrack = track as? RemoteTrackPublication, remoteTrack.isSubscribed {
                                            Button {
                                                Task {
                                                    try! await remoteTrack.set(subscribed: false)
                                                }
                                            } label: {
                                                Text("Disconnect")
                                                    .padding(8)
                                                    .background(RoundedRectangle(cornerRadius: 8).fill(viewState.theme.error))
                                                    .transition(.opacity)
                                            }
                                            
                                        }
                                    }
                                }
                                
                                VoiceChannelBox(title: title) {
                                    Avatar(user: user.user, member: user.member, width: 48, height: 48)
                                } trailing: {
                                    if !participant.audioTracks.contains { track in
                                        track.source == .microphone && track.kind == .audio && !track.isMuted
                                    } {
                                        Image(systemName: "mic.slash.fill")
                                            .resizable()
                                            .scaledToFit()
                                        .frame(width: 16, height: 16)
                                    }
                                }
                                .addBorder(participant.isSpeaking ? Color.green : Color.clear, width: 1, cornerRadius: 8)
                            }
                        }
                    } else {
                        HStack(alignment: .center) {
                            VStack(alignment: .center) {
                                Text("Not Connected")
                                    .font(.title)
                                Text("Click the join button to connect")
                                    .font(.subheadline)
                            }
                        }
                    }
                }
                .contentMargins(.top, 16, for: .scrollContent)
                
                //Spacer()
                
                HStack(spacing: 12) {
                    Group {
                        Button {
                            Task {
                                if inCall, await AVAudioApplication.requestRecordPermission() {
                                    unmuted.toggle()
                                }
                            }
                        } label: {
                            Image(systemName: unmuted ? "mic.fill" : "mic.slash.fill")
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                        }
                        
                        // Two different mechanisms behind one button: iOS
                        // hands the whole device to a ReplayKit broadcast
                        // extension, Mac captures a display in-process with
                        // ScreenCaptureKit. They share no API at all, only
                        // the resulting screen-share track.
                        Button {
                            guard inCall else { return }
                            #if targetEnvironment(macCatalyst)
                            toggleMacScreenShare()
                            #else
                            if screenSharing {
                                BroadcastManager.shared.requestStop()
                            } else if let reason = screenShareUnavailableReason {
                                // requestActivation() just asks the system to
                                // put up the picker and returns; when nothing
                                // can service that request it fails silently,
                                // leaving a button that looks broken. Say why
                                // instead.
                                callAlertMessage = reason
                            } else {
                                // Shows the system broadcast picker -- only
                                // the system UI is allowed to start a
                                // whole-device recording, an app can't
                                // trigger it silently. Once the user picks
                                // this app's extension and confirms, the
                                // extension captures the whole screen (any
                                // app, the home screen, everything) and
                                // LiveKit auto-publishes it as our screen
                                // share track -- see the isBroadcastingPublisher
                                // handling below.
                                BroadcastManager.shared.requestActivation()
                            }
                            #endif
                        } label: {
                            Image(systemName: screenSharing ? "desktopcomputer.and.arrow.down" : "desktopcomputer")
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                        }

                        if screenSharing && replayRecorder.isAvailable {
                            Menu {
                                ForEach(Self.replayDurations, id: \.self) { seconds in
                                    Button {
                                        saveReplay(seconds: seconds)
                                    } label: {
                                        Text(seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m")
                                    }
                                }
                            } label: {
                                Image(systemName: "film")
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                            }
                        }

                        Button { inCall.toggle() } label: {
                            Text(inCall ? "Leave Call" : "Join Call")
                                .font(.subheadline)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                        }
                        .frame(maxWidth: .infinity)
                        
                        Button {
                            withAnimation {
                                viewState.currentChannel = .force_textchannel(channel.id)
                            }
                        } label: {
                            Image(systemName: "bubble.fill")
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                        }
                        
                        Button { if inCall { defeaned.toggle() } } label: {
                            Image(systemName: defeaned ? "speaker.slash.fill" : "speaker.wave.3.fill")
                                .frame(width: 16, height: 16)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                            
                        }
                    }
                    .buttonBorderShape(.capsule)
                    .background(viewState.theme.accent)
                    .clipShape(.capsule)
                }
            }
            .padding([.horizontal, .bottom], 16)
        }
        .background(viewState.theme.background)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: inCall, { _, inCall in
            if inCall && viewState.currentVoiceChannel == channel.id {
                return
            }
            
            if inCall {
                Task {
                    await connect()
                }
            } else {
                Task {
                    await disconnect()
                }
            }
        })
        .onChange(of: unmuted, { @MainActor _, unmuted in
            if let room = viewState.currentVoice {
                Task {
                    if unmuted {
                        try! await room.localParticipant.setMicrophone(enabled: true)
                    } else if let micTrack = room.localParticipant.localAudioTracks.first {
                        try! await room.localParticipant.unpublish(publication: micTrack)
                    }
                }
            }
        })
        .onReceive(broadcastPublisher) { isBroadcasting in
            // Mac drives screenSharing from its own ScreenCaptureKit
            // capturer; this publisher only ever reports the iOS broadcast
            // extension, so letting it through there would tear down a Mac
            // share the moment it reported "not broadcasting".
            #if targetEnvironment(macCatalyst)
            return
            #else
            // Only act on an actual transition. The subject replays its
            // current value to every new subscriber, so without this an
            // emission that changes nothing still writes @State -- and a
            // @State write always invalidates, even when the value is
            // identical.
            guard screenSharing != isBroadcasting else { return }
            screenSharing = isBroadcasting
            // Starting is handled by VoiceChannelDelegate.didPublishTrack,
            // once the screen-share track the extension feeds actually
            // appears. Stopping the broadcast (from here, Control Center,
            // or the extension itself) doesn't automatically unpublish the
            // track on its own, so that's done explicitly.
            guard !isBroadcasting else { return }
            replayRecorder.stop()
            if let room = viewState.currentVoice,
               let publication = room.localParticipant.localVideoTracks.first(where: { $0.source == .screenShareVideo }) {
                Task { try? await room.localParticipant.unpublish(publication: publication) }
            }
            #endif
        }
        .onChange(of: updater, { _, _ in })
        .task {
            // resync state when view is reopened
            if viewState.currentVoiceChannel == channel.id {
                inCall = true
            }
        }
        .alert(callAlertMessage ?? "", isPresented: Binding(
            get: { callAlertMessage != nil },
            set: { shown in if !shown { callAlertMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        }
    }
}

class VoiceChannelDelegate: RoomDelegate {
    @Binding var updater: Bool
    let annotationController: AnnotationController
    let replayRecorder: ReplayBufferRecorder

    init(updater: Binding<Bool>, annotationController: AnnotationController, replayRecorder: ReplayBufferRecorder) {
        self._updater = updater
        self.annotationController = annotationController
        self.replayRecorder = replayRecorder
    }
    func roomDidConnect(_ room: Room) {
        print(room)
    }

    func room(_ room: Room, participant: RemoteParticipant?, didReceiveData data: Data, forTopic topic: String, encryptionType: EncryptionType) {
        guard topic == "annotate" else { return }
        // Without a verified sender the annotation can't be attributed to
        // anyone, so drop it rather than trusting the payload.
        guard let sender = participant?.identity?.stringValue else { return }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        Task { @MainActor in
            self.annotationController.applyEvent(json, senderId: sender)
        }
    }
    
    func roomDidReconnect(_ room: Room) {
        print("reconnected")
    }
    
    func roomIsReconnecting(_ room: Room) {
        print("reconnecting")
    }
    
    func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        print(error)
    }
    
    func room(_ room: Room, trackPublication: TrackPublication, didUpdateE2EEState state: E2EEState) {
        print("track publication \(trackPublication.kind), \(trackPublication.source)")
        print(trackPublication.track)
        
        self.updater.toggle()
    }
    
    func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        self.updater.toggle()
    }
    
    func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        self.updater.toggle()
    }
    
    func room(_ room: Room, participant: LocalParticipant, didPublishTrack publication: LocalTrackPublication) {
        print("local \(publication.kind), \(publication.source)")
        print(publication.track)

        if publication.source == .screenShareVideo, let videoTrack = publication.track as? VideoTrack {
            replayRecorder.start(track: videoTrack)
        }

        self.updater.toggle()
    }

    func room(_ room: Room, participant: LocalParticipant, didUnpublishTrack publication: LocalTrackPublication) {
        if publication.source == .screenShareVideo {
            replayRecorder.stop()
        }

        self.updater.toggle()
    }
    
    func room(_ room: Room, participant: RemoteParticipant, didPublishTrack publication: RemoteTrackPublication) {
        print("remote \(publication.kind), \(publication.source)")
        print(publication.track)
        
        if publication.kind == .audio {
            Task { try! await publication.set(subscribed: true) }
        }
        
        self.updater.toggle()
    }
}

#Preview {
    let state = ViewState.preview()
    
    VoiceChannelView(
        channel: state.channels["1"]!,
        toggleSidebar: {},
        disableScroll: .constant(false),
        disableSidebar: .constant(false)
    )
    .applyPreviewModifiers(withState: state)
}
