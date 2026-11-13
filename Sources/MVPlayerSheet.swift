import AVFoundation
import AVKit
import SwiftUI

/// Dedicated YouTube Music-style theater MV player sheet.
/// Plays the official MV's own video + native audio stream together with zero drift.
struct MVPlayerSheet: View {
    @ObservedObject var player: Player
    @Environment(\.dismiss) private var dismiss

    @StateObject private var vm = TheaterMVController()
    @AppStorage("preferredVideoHeight") private var preferredVideoHeight: Int = 1080

    @State private var showControls = true
    @State private var hideTask: Task<Void, Never>?
    @State private var isDraggingSlider = false
    @State private var dragProgress: Double = 0
    @State private var isMuted = false
    @State private var playbackRate: Float = 1.0
    @State private var showMoreSheet = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Video viewport
            if let avPlayer = vm.avPlayer {
                TheaterVideoSurface(player: avPlayer)
                    .ignoresSafeArea()
                    .onTapGesture { toggleControls() }
            }

            // Loading or error indicator
            if vm.isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .scaleEffect(1.2)
                    Text(vm.statusText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                }
            } else if let error = vm.errorText {
                VStack(spacing: 12) {
                    Image(systemName: "video.slash")
                        .font(.system(size: 36))
                        .foregroundStyle(.white.opacity(0.6))
                    Text(error)
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.8))
                    Button("Retry") {
                        if let track = player.current {
                            vm.load(for: track, maxHeight: preferredVideoHeight, startAt: 0)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            }

            // YouTube Theater Bottom Overlay (matching the reference screenshot)
            if showControls {
                VStack(spacing: 0) {
                    // Top subtle bar for quick dismiss
                    HStack {
                        Button {
                            closePlayer()
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(10)
                                .background(Color.black.opacity(0.45))
                                .clipShape(Circle())
                        }
                        Spacer()
                        Text(vm.resolvedTitle)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(1)
                        Spacer()
                        Color.clear.frame(width: 38, height: 38)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 14)

                    Spacer()

                    // Bottom Theater Control Bar
                    VStack(spacing: 10) {
                        // 1. Full-width YouTube Red Scrubber Bar
                        GeometryReader { geo in
                            let w = max(1, geo.size.width)
                            let ratio = isDraggingSlider ? dragProgress : (vm.duration > 0 ? min(max(vm.currentTime / vm.duration, 0), 1) : 0)
                            ZStack(alignment: .leading) {
                                Rectangle()
                                    .fill(Color.white.opacity(0.28))
                                    .frame(height: isDraggingSlider ? 5 : 3)
                                Rectangle()
                                    .fill(Color(red: 1.0, green: 0.0, blue: 0.0))
                                    .frame(width: w * ratio, height: isDraggingSlider ? 5 : 3)
                                Circle()
                                    .fill(Color(red: 1.0, green: 0.0, blue: 0.0))
                                    .frame(width: isDraggingSlider ? 15 : 11, height: isDraggingSlider ? 15 : 11)
                                    .offset(x: max(0, min(w - 11, w * ratio - 5.5)))
                            }
                            .frame(height: 22)
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { val in
                                        isDraggingSlider = true
                                        dragProgress = min(max(val.location.x / w, 0), 1)
                                        scheduleAutoHide()
                                    }
                                    .onEnded { val in
                                        let finalRatio = min(max(val.location.x / w, 0), 1)
                                        vm.seek(to: finalRatio * vm.duration)
                                        isDraggingSlider = false
                                        scheduleAutoHide()
                                    }
                            )
                        }
                        .frame(height: 22)

                        // 2. Three-zone YouTube Theater Bar: [Left Controls + Time] [Center Track Info + Like] [Right Audio/Quality/Exit]
                        HStack(spacing: 16) {
                            // Left: Prev, Play/Pause, Next, Timecode
                            HStack(spacing: 18) {
                                Button {
                                    player.prev()
                                } label: {
                                    Image(systemName: "backward.end.fill")
                                        .font(.system(size: 17, weight: .semibold))
                                }

                                Button {
                                    vm.togglePlayPause()
                                    scheduleAutoHide()
                                } label: {
                                    Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                                        .font(.system(size: 22, weight: .bold))
                                        .frame(width: 24)
                                }

                                Button {
                                   _ =  player.next()
                                } label: {
                                    Image(systemName: "forward.end.fill")
                                        .font(.system(size: 17, weight: .semibold))
                                }

                                Text("\(formatTime(isDraggingSlider ? dragProgress * vm.duration : vm.currentTime)) / \(formatTime(vm.duration))")
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.85))
                            }
                            .foregroundStyle(.white)

                            Spacer(minLength: 8)

                            // Center: Mini Cover + Title/Artist + Like + More
                            if let track = player.current {
                                HStack(spacing: 10) {
                                    RemoteImage(url: track.artURL(size: 160), size: 36) { ArtPlaceholder() }
                                        .frame(width: 36, height: 36)
                                        .clipShape(RoundedRectangle(cornerRadius: 4))

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(track.title)
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(.white)
                                            .lineLimit(1)
                                        Text(track.artist)
                                            .font(.system(size: 11))
                                            .foregroundStyle(.white.opacity(0.7))
                                            .lineLimit(1)
                                    }
                                    .frame(maxWidth: 220, alignment: .leading)

                                    Button {
                                        player.toggleFavorite()
                                        scheduleAutoHide()
                                    } label: {
                                        Image(systemName: player.isCurrentFavorite ? "hand.thumbsup.fill" : "hand.thumbsup")
                                            .font(.system(size: 16))
                                            .foregroundStyle(player.isCurrentFavorite ? .white : .white.opacity(0.85))
                                    }

                                    Button {
                                        showMoreSheet = true
                                    } label: {
                                        Image(systemName: "ellipsis.vertical")
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundStyle(.white.opacity(0.85))
                                            .padding(.horizontal, 4)
                                    }
                                }
                            }
                                                      Spacer(minLength: 8)

                            // Right: Mute, Quality Menu, Speed Menu, Exit Fullscreen
                            HStack(spacing: 18) {
                                Button {
                                    isMuted.toggle()
                                    vm.setMuted(isMuted)
                                    scheduleAutoHide()
                                } label: {
                                    Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                        .font(.system(size: 16))
                                }

                                // Quality Picker (2160p / 1080p / 720p / 480p)
                                Menu {
                                    ForEach([2160, 1080, 720, 480], id: \.self) { h in
                                        Button {
                                            let resumeAt = vm.currentTime
                                            preferredVideoHeight = h
                                            if let track = player.current {
                                                vm.load(for: track, maxHeight: h, startAt: resumeAt)
                                            }
                                        } label: {
                                            Label(h == 2160 ? "2160p (4K)" : "\(h)p",
                                                  systemImage: preferredVideoHeight == h ? "checkmark" : "")
                                        }
                                    }
                                } label: {
                                    Text(preferredVideoHeight == 2160 ? "4K" : "\(preferredVideoHeight)p")
                                        .font(.system(size: 11, weight: .bold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                        A                .background(Color.white.opacity(0.16))
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                }

                                // Speed Picker
                                Menu {
                                    ForEach([Float(0.75), 1.0, 1.25, 1.5], id: \.self) { rate in
                                        Button {
                                            playbackRate = rate
                                            vm.setRate(rate)
                                        } label: {
                                            Label(rate == 1.0 ? "Normal (1x)" : "\(String(format: "%.2gx", rate))",
                                                  systemImage: playbackRate == rate ? "checkmark" : "")
                                        }
                                    }
                                } label: {
                                    Image(systemName: "gearshape")
                                        .font(.system(size: 16))
                                }

                                // Exit Theater MV Player
                                Button {
                                    closePlayer()
                                } label: {
                                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                                        .font(.system(size: 16, weight: .semibold))
                                }
                            }
                            .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 16)
                    }
                    .background(
                        LinearGradient(
                            colors: [.clear, .black.opacity(0.65), .black.opacity(0.9)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .ignoresSafeArea()
                    )
                }
                .transition(.opacity)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .onAppear {
            if player.isPlaying {
                player.togglePlay()
            }
            if let track = player.current {
                vm.load(for: track, maxHeight: preferredVideoHeight, startAt: 0)
            }
            scheduleAutoHide()
        }
        .onChange(of: player.current?.videoId) { _ in
            if let track = player.current {
                if player.isPlaying { player.togglePlay() }
                vm.load(for: track, maxHeight: preferredVideoHeight, startAt: 0)
            }
        }
        .onDisappear {
            vm.stop()
        }
        .sheet(isPresented: $showMoreSheet) {
            if let track = player.current {
                AddToPlaylistSheet(track: track)
            }
        }
    }

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) {
            showControls.toggle()
        }
        if showControls { scheduleAutoHide() }
    }

    private func scheduleAutoHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, !isDraggingSlider else { return }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.25)) {
                    showControls = false
                }
            }
        }
    }

    private func closePlayer() {
        vm.stop()
        dismiss()
    }

    private func formatTime(_ sec: Double) -> String {
        guard sec.isFinite, sec >= 0 else { return "0:00" }
        let total = Int(sec)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

@MainActor
private final class TheaterMVController: ObservableObject {
    @Published var avPlayer: AVPlayer?
    @Published var isLoading = true
    @Published var statusText = "Finding Official MV..."
    @Published var errorText: String?
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var resolvedTitle: String = ""

    private var backupAudioPlayer: AVPlayer?
    private var timeObserver: Any?
    private var loadTask: Task<Void, Never>?

    func load(for track: Track, maxHeight: Int, startAt: Double) {
        stop()
        isLoading = true
        errorText = nil
        statusText = "Loading Official MV..."
        resolvedTitle = track.title

        loadTask = Task {
            var targetVideoId = track.videoId
            if !track.isVideo, !track.title.isEmpty {
                let query = track.artist.isEmpty ? track.title : "\(track.title) \(track.artist) Official MV"
                let results = await YouTube.search(query, scope: .videos)
                let official = results.prefix(5).filter(\.isOfficialVideo)
                let pool = official.isEmpty ? Array(results.prefix(5)) : official
                if let best = pool.first {
                    targetVideoId = best.videoId
                    resolvedTitle = best.title
                }
            }

            guard !Task.isCancelled else { return }

            guard let found = await YouTube.videoStream(for: targetVideoId, maxHeight: maxHeight) else {
                isLoading = false
                errorText = "Unable to load MV stream"
                return
            }

            guard !Task.isCancelled else { return }

            let isHLS = found.url.pathExtension.lowercased() == "m3u8" || found.url.absoluteString.contains("://googlevideo.com")
            let vPlayer = buildAVPlayer(url: found.url, muted: false)

            if !isHLS {
                if let audioInfo = await YouTube.streamURL(for: targetVideoId) {
                    vPlayer.isMuted = true
                    let aPlayer = buildAVPlayer(url: audioInfo.url, muted: false)
                    self.backupAudioPlayer = aPlayer
                }
            }

            self.avPlayer = vPlayer
            if startAt > 0.5 {
                let cm = CMTime(seconds: startAt, preferredTimescale: 600)
                await vPlayer.seek(to: cm, toleranceBefore: .zero, toleranceAfter: .zero)
                await backupAudioPlayer?.seek(to: cm, toleranceBefore: .zero, toleranceAfter: .zero)
            }

            vPlayer.play()
            backupAudioPlayer?.play()
            self.isPlaying = true
            self.isLoading = false

            let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
            self.timeObserver = vPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
                guard let self else { return }
                let sec = time.seconds
                if sec.isFinite { self.currentTime = sec }
                if let dur = vPlayer.currentItem?.duration.seconds, dur.isFinite, dur > 0 {
                    self.duration = dur
                }
                self.isPlaying = vPlayer.rate > 0
                if let aPlayer = self.backupAudioPlayer, abs(aPlayer.currentTime().seconds - sec) > 0.25 {
                    aPlayer.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
                }
            }
        }
    }

    private func buildAVPlayer(url: URL, muted: Bool) -> AVPlayer {
        let asset = AVURLAsset(url: url, options: [
            AVURLAssetHTTPUserAgentKey: YouTube.visionUA
        ])
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 20
        let p = AVPlayer(playerItem: item)
        p.isMuted = muted
        p.automaticallyWaitsToMinimizeStalling = true
        return p
    }

    func togglePlayPause() {
        guard let avPlayer else { return }
        if avPlayer.rate > 0 {
            avPlayer.pause()
                      isPlaying = false
        } else {
            avPlayer.play()
            backupAudioPlayer?.play()
            isPlaying = true
        }
    }

    func seek(to seconds: Double) {
        let cm = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        avPlayer?.seek(to: cm, toleranceBefore: .zero, toleranceAfter: .zero)
        backupAudioPlayer?.seek(to: cm, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = seconds
    }

    func setMuted(_ muted: Bool) {
        if let backupAudioPlayer {
            backupAudioPlayer.isMuted = muted
        } else {
            avPlayer?.isMuted = muted
        }
    }

    func setRate(_ rate: Float) {
        avPlayer?.rate = rate
        backupAudioPlayer?.rate = rate
        isPlaying = rate > 0
    }

    func stop() {
        loadTask?.cancel()
        if let obs = timeObserver, let avPlayer {
            avPlayer.removeTimeObserver(obs)
        }
        timeObserver = nil
        avPlayer?.pause()
        avPlayer?.replaceCurrentItem(with: nil)
        avPlayer = nil
        backupAudioPlayer?.pause()
        backupAudioPlayer?.replaceCurrentItem(with: nil)
        backupAudioPlayer = nil
        isPlaying = false
    }
}

private struct TheaterVideoSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> TheaterPlayerContainer {
        let view = TheaterPlayerContainer()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: TheaterPlayerContainer, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
    }

    final class TheaterPlayerContainer: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
