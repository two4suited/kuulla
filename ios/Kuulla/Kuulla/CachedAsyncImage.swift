import ImageIO
import SwiftUI
import UIKit

// In-memory cache for downsampled artwork, keyed by URL + requested point size. Kuulla otherwise
// has no image caching at all — every artwork thumbnail is a bare AsyncImage, which re-downloads
// and re-decodes the full-resolution source (podcast art is commonly 1400x1400+) on every SwiftUI
// identity churn, including LazyVGrid cell recycling while scrolling (#559). The size is part of
// the key — not just the URL — because the same artwork is requested at different sizes (e.g. a
// 44pt row icon vs. a 110pt grid tile); keying on URL alone would let whichever size decoded first
// win the cache and hand a mismatched (blurry or oversized) thumbnail to the other call site.
final class ImageCache {
    static let shared = ImageCache()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 300
    }

    private static func key(url: URL, pointSize: CGFloat) -> NSString {
        "\(url.absoluteString)#\(Int(pointSize.rounded()))" as NSString
    }

    func image(for url: URL, pointSize: CGFloat) -> UIImage? {
        cache.object(forKey: Self.key(url: url, pointSize: pointSize))
    }

    func insert(_ image: UIImage, for url: URL, pointSize: CGFloat) {
        cache.setObject(image, forKey: Self.key(url: url, pointSize: pointSize))
    }
}

// Drop-in replacement for AsyncImage that downsamples to the displayed size (via ImageIO, off the
// main thread) and keeps the decoded result in ImageCache — so scrolling past a row that already
// loaded its artwork repaints instantly instead of re-fetching and re-decoding it.
struct CachedAsyncImage<Content: View, Placeholder: View>: View {
    private let url: URL?
    private let pointSize: CGFloat
    private let content: (Image) -> Content
    private let placeholder: () -> Placeholder

    @State private var uiImage: UIImage?

    init(
        url: URL?,
        pointSize: CGFloat,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.pointSize = pointSize
        self.content = content
        self.placeholder = placeholder
    }

    var body: some View {
        Group {
            if let uiImage {
                content(Image(uiImage: uiImage))
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            await load()
        }
    }

    private func load() async {
        guard let url else {
            uiImage = nil
            return
        }
        if let cached = ImageCache.shared.image(for: url, pointSize: pointSize) {
            uiImage = cached
            return
        }
        uiImage = nil
        guard let downsampled = await Self.downsampledImage(url: url, pointSize: pointSize)
        else { return }
        guard !Task.isCancelled else { return }
        ImageCache.shared.insert(downsampled, for: url, pointSize: pointSize)
        uiImage = downsampled
    }

    // Runs off the main actor: network fetch plus ImageIO thumbnail generation, which decodes
    // straight to the target pixel size instead of decoding the full-resolution source first.
    private static func downsampledImage(url: URL, pointSize: CGFloat) async -> UIImage? {
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            // 3x covers every current device scale; a mismatch just costs a slightly larger
            // decode than strictly necessary, never a blurry one.
            let maxPixelSize = pointSize * 3
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
                return nil
            }
            let thumbnailOptions =
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                ] as CFDictionary
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions)
            else { return nil }
            return UIImage(cgImage: cgImage)
        }.value
    }
}
