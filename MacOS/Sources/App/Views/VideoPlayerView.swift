import SwiftUI
import AVKit

/// Обёртка над `AVPlayerView`. На Android выбор дорожки делает ExoPlayer вместе с
/// `DeviceCapabilities`; на macOS этим занимается сам AVFoundation, поэтому
/// ограничение качества выражается через `preferredMaximumResolution`.
struct VideoPlayerView: NSViewRepresentable {
    let url: URL
    let resumeMs: Int
    let targetHeight: Int
    let onProgress: (Int, Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onProgress: onProgress) }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        context.coordinator.attach(to: view, url: url, resumeMs: resumeMs, targetHeight: targetHeight)
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) { }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator {
        private let onProgress: (Int, Int) -> Void
        private var player: AVPlayer?
        private var observer: Any?

        init(onProgress: @escaping (Int, Int) -> Void) {
            self.onProgress = onProgress
        }

        func attach(to view: AVPlayerView, url: URL, resumeMs: Int, targetHeight: Int) {
            let item = AVPlayerItem(url: url)
            if targetHeight > 0 {
                item.preferredMaximumResolution = CGSize(width: targetHeight * 16 / 9, height: targetHeight)
            }
            let player = AVPlayer(playerItem: item)
            self.player = player
            view.player = player

            if resumeMs > 0 {
                player.seek(to: CMTime(value: CMTimeValue(resumeMs), timescale: 1000),
                            toleranceBefore: .zero, toleranceAfter: .positiveInfinity)
            }
            // Прогресс сохраняется раз в пять секунд, как и в Android-плеере.
            observer = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 5, preferredTimescale: 1),
                queue: .main
            ) { [weak self] time in
                guard let self, let current = self.player?.currentItem else { return }
                let duration = current.duration.isNumeric ? current.duration.seconds : 0
                self.onProgress(Int(time.seconds * 1000),
                                duration.isFinite ? Int(duration * 1000) : 0)
            }
            player.play()
        }

        func detach() {
            if let observer { player?.removeTimeObserver(observer) }
            observer = nil
            player?.pause()
            player = nil
        }
    }
}
