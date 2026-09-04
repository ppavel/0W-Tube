import SwiftUI

/// Свежая подписанная ссылка добывается прямо перед воспроизведением — сохранённый
/// в карточке адрес это только вход для резолвера.
struct PlayerSheetView: View {
    let request: PlaybackRequest
    @ObservedObject var viewModel: SearchViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var streamUrl: URL?
    @State private var failure: String?
    @State private var isLoading = true
    @State private var lastPositionMs = 0
    @State private var lastDurationMs = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            player
        }
        .frame(minWidth: 860, minHeight: 560)
        .task {
            do {
                let info = try await StreamResolver.resolveForPlayback(request.item.playUrl,
                                                                       audioOnly: request.audioOnly)
                streamUrl = URL(string: info.streamUrl)
                if streamUrl == nil { failure = "Сервис вернул неверный адрес потока" }
            } catch {
                failure = HttpError.describe(error)
            }
            isLoading = false
        }
        .onDisappear { persist() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(request.item.title)
                    .font(.headline)
                    .lineLimit(1)
                subtitle
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button("Закрыть") { close() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(12)
    }

    private var subtitle: some View {
        HStack(spacing: 8) {
            Text(request.item.source)
            if !request.item.qualityLabel.isEmpty { Text(request.item.qualityLabel) }
            if request.audioOnly {
                Text("только звук")
            } else if request.targetHeight > 0 {
                Text("до \(request.targetHeight)p")
            }
        }
    }

    @ViewBuilder
    private var player: some View {
        if isLoading {
            ProgressView("Получаем поток…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let streamUrl {
            let height: Int = request.audioOnly ? 0 : request.targetHeight
            VideoPlayerView(url: streamUrl,
                            resumeMs: request.resumeMs,
                            targetHeight: height) { position, duration in
                lastPositionMs = position
                if duration > 0 { lastDurationMs = duration }
            }
        } else {
            failureView
        }
    }

    private var failureView: some View {
        let fallback: URL = URL(string: request.item.pageUrl) ?? URL(string: "https://rutube.ru/")!
        return VStack(spacing: 8) {
            Text("Не удалось получить поток").font(.headline)
            if let failure {
                Text(failure)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            Link("Открыть на сайте", destination: fallback)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func close() {
        persist()
        dismiss()
        viewModel.finishPlayback()
    }

    private func persist() {
        guard lastPositionMs > 0 else { return }
        viewModel.savePlaybackProgress(request, positionMs: lastPositionMs, durationMs: lastDurationMs)
    }
}
