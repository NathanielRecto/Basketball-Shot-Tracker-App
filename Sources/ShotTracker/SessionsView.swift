import AVFoundation
import AVKit
import SwiftUI

/// Recorded sessions, newest first: date, length, lens and made / shots. Tap one to watch it.
struct SessionsView: View {
    let onClose: () -> Void
    @State private var sessions: [SessionSummary] = []
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Group {
                if !loaded {
                    ProgressView()
                } else if sessions.isEmpty {
                    ContentUnavailableView("No recorded sessions yet", systemImage: "video.slash",
                                           description: Text("Tap Record on the camera screen; sessions you record appear here."))
                } else {
                    List {
                        ForEach(sessions) { s in
                            NavigationLink(value: s) { row(s) }
                        }
                        .onDelete { offsets in
                            for i in offsets { try? SessionStore.delete(sessions[i]) }
                            sessions.remove(atOffsets: offsets)
                        }
                    }
                }
            }
            .navigationTitle("Sessions")
            .navigationDestination(for: SessionSummary.self) { s in
                SessionDetailView(session: s) {
                    try? SessionStore.delete(s)
                    sessions.removeAll { $0 == s }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: onClose)
                }
            }
        }
        .task {
            sessions = await Task.detached { SessionStore.load() }.value
            loaded = true
        }
    }

    private func row(_ s: SessionSummary) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(s.started.formatted(date: .abbreviated, time: .shortened)).font(.headline)
                Text("\(SessionStore.clock(s.seconds)) · \(s.lens) lens\(s.hasVideo ? "" : " · no video")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(s.made) / \(s.attempts)").font(.title3.weight(.semibold)).monospacedDigit()
            Text(s.fgText).font(.callout).foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
        }
    }
}

/// The session's video with the app's calls: stats, the shot list (tap to jump there) and a MADE / MISSED banner on
/// the video when playback reaches each call.
struct SessionDetailView: View {
    let session: SessionSummary
    let onDelete: () -> Void
    @StateObject private var playback: Playback
    @State private var confirmDelete = false
    @Environment(\.dismiss) private var dismiss

    init(session: SessionSummary, onDelete: @escaping () -> Void) {
        self.session = session
        self.onDelete = onDelete
        _playback = StateObject(wrappedValue: Playback(url: session.hasVideo ? session.videoURL : nil))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack(alignment: .bottomLeading) {
                if let player = playback.player {
                    PlayerView(player: player)
                } else {
                    Color.black.overlay(Text("No video in this session").foregroundStyle(.white))
                }
                if let shot = callShowing { banner(shot).padding(12).allowsHitTesting(false) }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 10) {
                stats
                List(Array(session.shots.enumerated()), id: \.offset) { i, shot in
                    Button { playback.seek(to: shot.tRelease - 1) } label: { shotRow(i, shot) }
                }
                .listStyle(.plain)
            }
            .frame(minWidth: 230, maxWidth: 300)
        }
        .padding()
        .navigationTitle(session.started.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if session.hasVideo {
                ToolbarItem { ShareLink(item: session.videoURL) }
            }
            ToolbarItem {
                Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
            }
        }
        .confirmationDialog("Delete this session and its video?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                playback.player?.pause()
                onDelete()
                dismiss()
            }
        }
        .onDisappear { playback.player?.pause() }
    }

    /// The call to show over the video: from the moment the app made it, for 2 s.
    private var callShowing: SessionRecorder.Shot? {
        session.shots.last { playback.time >= $0.tCross && playback.time < $0.tCross + 2 }
    }

    private var stats: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(session.made) / \(session.attempts)").font(.system(size: 34, weight: .bold, design: .rounded))
                Text(session.fgText).font(.title3).foregroundStyle(.secondary)
            }
            Text("Made \(session.made) · Missed \(session.attempts - session.made) · \(SessionStore.clock(session.seconds)) · \(session.lens) lens")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func shotRow(_ i: Int, _ shot: SessionRecorder.Shot) -> some View {
        let made = shot.outcome == "made"
        return HStack {
            Text("\(i + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 22, alignment: .trailing)
            Text(SessionStore.clock(shot.tCross)).font(.callout.monospacedDigit())
            Text(made ? "MADE" : "MISSED")
                .font(.caption.weight(.heavy))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(made ? Color.green : Color.red, in: Capsule())
            Text(LiveView.reasonText(shot.reason)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func banner(_ shot: SessionRecorder.Shot) -> some View {
        let made = shot.outcome == "made"
        return VStack(alignment: .leading, spacing: 0) {
            Text(made ? "MADE" : "MISSED").font(.system(size: 30, weight: .heavy, design: .rounded))
            Text(LiveView.reasonText(shot.reason)).font(.caption)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background((made ? Color.green : Color.red).opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// The system video player (play / pause, scrubbing, full screen). SwiftUI's VideoPlayer lives in a cross-import
/// overlay that this SwiftPM build does not link, so AVPlayerViewController is wrapped directly.
struct PlayerView: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        vc.player = player
    }
}

/// An AVPlayer plus its current time (for the banner), updated 10 times a second.
@MainActor
final class Playback: ObservableObject {
    let player: AVPlayer?
    @Published var time = 0.0
    private var observer: Any?

    init(url: URL?) {
        player = url.map { AVPlayer(url: $0) }
        observer = player?.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.time = t.seconds }
        }
    }

    deinit {
        if let observer { player?.removeTimeObserver(observer) }
    }

    func seek(to seconds: Double) {
        guard let player else { return }
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
    }
}
