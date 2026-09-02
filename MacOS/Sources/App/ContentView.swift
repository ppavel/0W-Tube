import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = SearchViewModel()
    @FocusState private var searchFieldFocused: Bool
    
    private let columns = [
        GridItem(.adaptive(minimum: 200), spacing: 20)
    ]
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search RUTUBE...", text: $viewModel.query)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
                    .focused($searchFieldFocused)
                    .onSubmit {
                        Task { await viewModel.search() }
                    }
                
                Button("Search") {
                    Task { await viewModel.search() }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
            
            Divider()
            
            if viewModel.isLoading {
                ProgressView("Searching...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.results.isEmpty && !viewModel.query.isEmpty {
                Text("No results found")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(viewModel.results) { video in
                            Button(action: {
                                viewModel.selectedVideo = video
                            }) {
                                VideoCardView(video: video)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
                }
            }
        }
        .sheet(item: $viewModel.selectedVideo) { video in
            PlayerSheetView(video: video, viewModel: viewModel)
        }
    }
}

struct VideoCardView: View {
    let video: Video
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .aspectRatio(16/9, contentMode: .fit)
                
                if let url = video.thumbnailUrl {
                    AsyncImage(url: url) { image in
                        image.resizable()
                            .aspectRatio(16/9, contentMode: .fill)
                    } placeholder: {
                        ProgressView()
                    }
                    .cornerRadius(8)
                }
            }
            .cornerRadius(8)
            
            Text(video.title)
                .font(.system(size: 14))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .foregroundColor(.primary)
            
            Text(video.source)
                .font(.caption)
                .foregroundColor(.blue)
        }
        .padding(8)
        .background(Color.gray.opacity(0.05))
        .cornerRadius(10)
    }
}

struct PlayerSheetView: View {
    let video: Video
    let viewModel: SearchViewModel
    @Environment(\.dismiss) var dismiss
    @State private var streamUrl: URL?
    @State private var isLoading = true
    
    var body: some View {
        VStack {
            HStack {
                Text(video.title)
                    .font(.headline)
                Spacer()
                Button("Close") { dismiss() }
            }
            .padding()
            
            if isLoading {
                ProgressView("Resolving stream...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let url = streamUrl {
                VideoPlayerView(url: url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("Failed to resolve stream")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        .task {
            streamUrl = await viewModel.getStreamUrl(for: video)
            isLoading = false
        }
    }
}
