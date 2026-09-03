import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = SearchViewModel()
    @FocusState private var searchFieldFocused: Bool

    private let columns = [GridItem(.adaptive(minimum: 240), spacing: 18)]

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            filterBar
            Divider()
            statusBar
            content
        }
        .sheet(item: $viewModel.playback) { request in
            PlayerSheetView(request: request, viewModel: viewModel)
        }
        .onAppear {
            viewModel.restore()
            searchFieldFocused = true
        }
        // Пункты меню, которым нужен доступ к модели: AppKit-меню живет вне
        // SwiftUI-иерархии и достучаться до `@StateObject` может только так.
        .onReceive(NotificationCenter.default.publisher(for: .tubeFocusSearch)) { _ in
            searchFieldFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .tubeRepeatSearch)) { _ in
            if viewModel.playback == nil { viewModel.search() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .tubeCloseSheet)) { _ in
            viewModel.finishPlayback()
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            TextField("Поиск по RUTUBE, VK Video, Дзен, OK и PeerTube", text: $viewModel.query)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
                .focused($searchFieldFocused)
                .onSubmit { viewModel.search() }

            Button("Найти") { viewModel.search() }
                .keyboardShortcut(.defaultAction)

            Button {
                viewModel.toggleTrafficMode()
            } label: {
                Label("Экономия трафика", systemImage: "tortoise")
                    .labelStyle(.iconOnly)
            }
            .help("Режим экономии трафика: низкое качество и звук отдельно")
            .foregroundColor(viewModel.trafficMode ? .accentColor : .secondary)

            Button {
                viewModel.toggleHistoryMode()
            } label: {
                Label("История", systemImage: "clock.arrow.circlepath")
                    .labelStyle(.iconOnly)
            }
            .help("Недосмотренные ролики")
            .foregroundColor(viewModel.historyMode ? .accentColor : .secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(viewModel.filterLabels.enumerated()), id: \.offset) { index, label in
                    Button(label) { viewModel.selectFilter(index) }
                        .buttonStyle(.borderless)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(index == viewModel.selectedFilter
                                    ? Color.accentColor.opacity(0.22) : Color.gray.opacity(0.12))
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
        .disabled(viewModel.historyMode)
        .opacity(viewModel.historyMode ? 0.4 : 1)
    }

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !viewModel.status.isEmpty {
                Text(viewModel.status)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            // На Android ошибки источников собираются, но не показываются; на macOS
            // места хватает, и знать, какой бэкенд отвалился, полезно.
            ForEach(viewModel.sourceErrors, id: \.self) { error in
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.orange)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.items.isEmpty {
            VStack(spacing: 6) {
                Text(viewModel.historyMode ? "История пуста" : "Ничего не найдено")
                    .foregroundColor(.secondary)
                if !viewModel.historyMode {
                    Text("Прогресс сохраняется после первой минуты просмотра")
                        .font(.caption)
                        .foregroundColor(.secondary.opacity(0.7))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(viewModel.items) { item in
                        Button {
                            viewModel.play(item)
                        } label: {
                            VideoCardView(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(14)
            }
        }
    }
}

struct VideoCardView: View {
    let item: VideoItem

    private var progress: Double {
        let watched = WatchProgressStore.get(item)
        let duration = watched.durationMs > 0 ? watched.durationMs : item.durationMs
        guard watched.positionMs > 0, duration > 0 else { return 0 }
        return min(1, Double(watched.positionMs) / Double(duration))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottom) {
                Rectangle()
                    .fill(Color.gray.opacity(0.18))
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .overlay {
                        if let url = item.thumbnailUrl {
                            AsyncImage(url: url) { image in
                                image.resizable().aspectRatio(contentMode: .fill)
                            } placeholder: {
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                    .clipped()

                HStack(alignment: .bottom) {
                    if !item.qualityLabel.isEmpty { badge(item.qualityLabel) }
                    Spacer()
                    if !item.durationLabel.isEmpty { badge(item.durationLabel) }
                }
                .padding(6)

                if progress > 0 {
                    GeometryReader { geometry in
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(width: geometry.size.width * progress, height: 3)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(item.title)
                .font(.system(size: 13))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundColor(.primary)

            Text(item.source)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(8)
        .background(Color.gray.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.monospacedDigit())
            .foregroundColor(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.black.opacity(0.65))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
