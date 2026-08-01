import SwiftUI

/// Remote image with an app-wide in-memory cache — unlike AsyncImage,
/// repeated renders (the PR list re-evaluates on every poll and
/// timestamp tick) reuse the decoded image instead of re-fetching.
struct RemoteImage<Placeholder: View>: View {
    let url: URL?
    @ViewBuilder let placeholder: () -> Placeholder

    @State private var image: NSImage?

    private static var cache: NSCache<NSURL, NSImage> { ImageCache.shared }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url else { return }
            if let cached = Self.cache.object(forKey: url as NSURL) {
                image = cached
                return
            }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let loaded = NSImage(data: data) else { return }
                Self.cache.setObject(loaded, forKey: url as NSURL)
                image = loaded
            } catch {
                if PreviewMode.isActive {
                    print("IMG FAIL \(url): \(error.localizedDescription)")
                    fflush(stdout)
                }
            }
        }
    }
}

private enum ImageCache {
    static let shared = NSCache<NSURL, NSImage>()
}
