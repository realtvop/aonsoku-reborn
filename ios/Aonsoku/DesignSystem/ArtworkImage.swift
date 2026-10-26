import AonsokuKit
import Perception
import SwiftUI

/// Square cover art from the cover cache, with a symbol while it loads or
/// when there is none.
struct ArtworkImage: View {
    let id: String?
    var size: ArtworkSize = .medium
    var cornerRadius: CGFloat = 8
    /// Round, for artists.
    var isCircular = false
    var placeholder = "music.note"

    var body: some View {
        WithPerceptionTracking {
            ArtworkReader(id: id, size: size) { image in
                WithPerceptionTracking {
                    Rectangle()
                        .fill(.fill.tertiary)
                        .overlay {
                            WithPerceptionTracking {
                                if let image {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFill()
                                        .transition(.opacity)
                                } else {
                                    PlaceholderSymbol(name: placeholder)
                                }
                            }
                        }
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(shape)
                        .overlay {
                            WithPerceptionTracking {
                                shape.stroke(.primary.opacity(0.08), lineWidth: 0.5)
                            }
                        }
                        .animation(.easeOut(duration: 0.2), value: image != nil)
                }
            }
            .accessibilityHidden(true)
        }
    }

    private var shape: AnyShape {
        isCircular
            ? AnyShape(Circle())
            : AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// Cover art filling whatever frame it is given, cropped around `focus`,
/// for full-bleed headers. Shows nothing until the image loads.
struct ArtworkBackdrop: View {
    let id: String?
    var size: ArtworkSize = .large
    /// The point of the image kept in view when it is cropped; a little
    /// above the middle keeps faces in an artist photo.
    var focus = UnitPoint(x: 0.5, y: 0.4)

    var body: some View {
        WithPerceptionTracking {
            ArtworkReader(id: id, size: size) { image in
                WithPerceptionTracking {
                    GeometryReader { proxy in
                        WithPerceptionTracking {
                            if let image {
                                let frame = Self.fill(image.size, in: proxy.size, focus: focus)
                                Image(uiImage: image)
                                    .resizable()
                                    .frame(width: frame.width, height: frame.height)
                                    .offset(x: frame.minX, y: frame.minY)
                                    .transition(.opacity)
                            }
                        }
                    }
                    .clipped()
                    .animation(.easeOut(duration: 0.3), value: image != nil)
                }
            }
            .accessibilityHidden(true)
        }
    }

    /// Where an image of `imageSize` goes to fill `bounds` with `focus` as
    /// close to the middle as the image's edges allow.
    static func fill(_ imageSize: CGSize, in bounds: CGSize, focus: UnitPoint) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(origin: .zero, size: bounds)
        }
        let scale = max(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        let x = min(max(bounds.width / 2 - width * focus.x, bounds.width - width), 0)
        let y = min(max(bounds.height / 2 - height * focus.y, bounds.height - height), 0)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

/// Loads cover art from memory, the cover cache or the server and hands
/// it to `content`: nil while it loads or when there is none. A cached
/// image is there on the first frame, so rows do not flash while scrolling;
/// a smaller one in memory stands in while a larger size loads.
struct ArtworkReader<Content: View>: View {
    let id: String?
    var size: ArtworkSize = .medium
    @ViewBuilder let content: (UIImage?) -> Content

    @Environment(AppModel.self) private var app
    @State private var loaded: LoadedImage?

    var body: some View {
        WithPerceptionTracking {
            content(currentImage)
                .task(id: key) { await load() }
                .onReceive(
                    NotificationCenter.default.publisher(for: .aonsokuCoverImageCached)
                ) { notification in
                    guard let id,
                          notification.userInfo?[ImageCacheNotification.coverArtIdKey]
                              as? String == id else {
                        return
                    }
                    Task { await load() }
                }
        }
    }

    private var key: String? {
        id.map { "\($0)@\(size.rawValue)" }
    }

    private var currentImage: UIImage? {
        guard let key, let id else { return nil }
        if let loaded, loaded.key == key { return loaded.image }
        return app.artwork.cachedImage(for: id, size: size)
            ?? app.artwork.previewImage(for: id, size: size)
    }

    private func load() async {
        guard let key, let id else { return }
        if loaded?.key == key { return }
        if let image = await app.artwork.image(for: id, size: size), !Task.isCancelled {
            loaded = LoadedImage(key: key, image: image)
        }
    }
}

/// The signed-in user's avatar, or their initial.
struct AvatarImage: View {
    let username: String
    var size: CGFloat = 32

    @Environment(AppModel.self) private var app
    @State private var image: UIImage?

    var body: some View {
        WithPerceptionTracking {
            Circle()
                .fill(.tint)
                .overlay {
                    WithPerceptionTracking {
                        LinearGradient(colors: [.white.opacity(0.2), .clear], startPoint: .top, endPoint: .bottom)
                    }
                }
                .overlay {
                    WithPerceptionTracking {
                        if let image {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Text(username.prefix(1).uppercased())
                                .font(.system(size: size * 0.45, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                        }
                    }
                }
                .frame(width: size, height: size)
                .clipShape(.circle)
                .task(id: username) {
                    image = await app.artwork.avatar(username: username)
                }
                .accessibilityHidden(true)
        }
    }
}

private struct LoadedImage {
    let key: String
    let image: UIImage
}

private struct PlaceholderSymbol: View {
    let name: String

    var body: some View {
        WithPerceptionTracking {
            GeometryReader { proxy in
                WithPerceptionTracking {
                    Image(systemName: name)
                        .font(.system(size: max(proxy.size.width * 0.3, 10), weight: .medium))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
}
