import SwiftUI

// MARK: - Poster in griglia (stile Letterboxd)

struct BookCardView: View {
    let book: BookItem
    var showsMeta = true

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            BookCoverView(path: book.coverPath, title: book.title, author: book.author)
                .overlay(alignment: .topLeading) {
                    if book.status == .reading {
                        Text("IN LETTURA")
                            .font(.system(size: 8, weight: .heavy))
                            .tracking(0.6)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 3)
                            .background(Color.pbBlue, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                            .foregroundStyle(.white)
                            .padding(5)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if book.hasPersonalPhoto {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(.black.opacity(0.45), in: Circle())
                            .padding(5)
                    }
                }
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)

            if showsMeta {
                HStack(spacing: 4) {
                    if book.isRated {
                        RatingStarsDisplay(rating: book.rating, size: 9)
                    }
                    Spacer(minLength: 0)
                    if book.rereadCount > 0 {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.pbBlue)
                    }
                    if book.liked {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.pbOrange)
                    }
                }
                .frame(height: 12)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityText: String {
        var parts = ["\(book.title), di \(book.author)"]
        if book.isRated { parts.append(RatingFormatter.spoken(book.rating)) }
        if book.liked { parts.append("Mi piace") }
        if book.status == .reading { parts.append("In lettura") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Riga per liste

struct BookRowView: View {
    let book: BookItem
    var showsRating = true

    var body: some View {
        HStack(spacing: 14) {
            BookCoverView(path: book.coverPath, title: book.title, author: book.author, cornerRadius: 4, maxPixelSize: 240)
                .frame(width: 50)

            VStack(alignment: .leading, spacing: 4) {
                Text(book.title)
                    .font(.headline)
                    .lineLimit(2)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Color.pbTextSecondary)
                    .lineLimit(1)
                if showsRating && (book.isRated || book.liked) {
                    HStack(spacing: 6) {
                        if book.isRated {
                            RatingStarsDisplay(rating: book.rating, size: 11)
                        }
                        if book.liked {
                            Image(systemName: "heart.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.pbOrange)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        [book.author.nilIfBlank, book.publicationYear.map { String($0) }]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}

// MARK: - Copertina con caricamento asincrono dal disco

@MainActor
struct BookCoverView: View {
    let path: String?
    let title: String
    let author: String
    var cornerRadius: CGFloat = 6
    var maxPixelSize: CGFloat = 600

    @State private var image: UIImage? = nil
    @State private var loadedPath: String? = nil

    var body: some View {
        Color.pbSurfaceElevated
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                } else {
                    CoverPlaceholderView(title: title, author: author)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
            .task(id: path) { await loadImage() }
    }

    private func loadImage() async {
        guard let path else {
            image = nil
            loadedPath = nil
            return
        }
        guard path != loadedPath || image == nil else { return }
        if path != loadedPath { image = nil }

        let loaded = await ImageStorageManager.shared.loadThumbnail(relativePath: path, maxPixelSize: maxPixelSize)
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            image = loaded
        }
        loadedPath = path
    }
}

// MARK: - Immagine salvata in proporzioni originali

@MainActor
struct StoredImageView<Placeholder: View>: View {
    let path: String
    var maxPixelSize: CGFloat
    private let placeholder: () -> Placeholder

    @State private var image: UIImage? = nil

    init(
        path: String,
        maxPixelSize: CGFloat = ImageStorageManager.maxPixelDimension,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.path = path
        self.maxPixelSize = maxPixelSize
        self.placeholder = placeholder
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                placeholder()
            }
        }
        .task(id: path) {
            image = await ImageStorageManager.shared.loadThumbnail(relativePath: path, maxPixelSize: maxPixelSize)
        }
    }
}

// MARK: - Copertina generata quando manca un'immagine

struct CoverPlaceholderView: View {
    let title: String
    let author: String

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .topLeading) {
                LinearGradient(
                    colors: Self.palette(for: title + author),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                VStack(alignment: .leading, spacing: 4) {
                    Text(title.nilIfBlank ?? "Senza titolo")
                        .font(.system(size: max(9, width * 0.12), weight: .bold, design: .serif))
                        .lineLimit(4)
                        .minimumScaleFactor(0.6)
                    Spacer(minLength: 0)
                    Text(author)
                        .font(.system(size: max(7, width * 0.08), weight: .medium))
                        .lineLimit(2)
                        .opacity(0.85)
                }
                .foregroundStyle(.white)
                .padding(max(6, width * 0.09))
            }
        }
    }

    /// Colori deterministici calcolati dal titolo, stabili tra un avvio e l'altro.
    static func palette(for seed: String) -> [Color] {
        let hash = seed.unicodeScalars.reduce(5381) { (partial: Int, scalar: Unicode.Scalar) -> Int in
            ((partial &* 33) &+ Int(scalar.value)) & 0x7FFF_FFFF
        }
        let hue = Double(hash % 360) / 360
        let secondHue = (hue + 0.08).truncatingRemainder(dividingBy: 1)
        return [
            Color(hue: hue, saturation: 0.5, brightness: 0.55),
            Color(hue: secondHue, saturation: 0.6, brightness: 0.3)
        ]
    }
}

// MARK: - Badge

struct BadgeView: View {
    let text: String
    var systemImage: String?
    var tint: Color = .pbGreen

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .foregroundStyle(tint)
        .background(tint.opacity(0.14), in: Capsule())
    }
}

// MARK: - Chip dei filtri

struct FilterChip: View {
    let title: String
    var systemImage: String?
    var isSelected: Bool

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption.weight(.bold))
            }
            Text(title)
                .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .foregroundStyle(isSelected ? Color.pbBackground : Color.primary)
        .background(
            Capsule().fill(isSelected ? Color.pbGreen : Color.pbSurfaceElevated)
        )
        .contentShape(Capsule())
    }
}
