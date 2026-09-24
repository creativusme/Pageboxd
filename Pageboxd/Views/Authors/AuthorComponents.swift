import SwiftUI

/// Destinazione di navigazione verso la ricerca online degli autori.
struct AuthorSearchRoute: Hashable {
    var query: String = ""
}

extension View {
    /// Destinazioni comuni a tutte le schede: dettaglio libro, scheda autore, ricerca autori.
    func pageboxdDestinations() -> some View {
        navigationDestination(for: BookItem.self) { book in
            BookDetailView(book: book)
        }
        .navigationDestination(for: AuthorRoute.self) { route in
            AuthorDetailView(route: route)
        }
        .navigationDestination(for: AuthorSearchRoute.self) { route in
            AuthorSearchView(initialQuery: route.query)
        }
    }
}

// MARK: - Avatar autore

/// Foto dell'autore salvata sul dispositivo, oppure remota, oppure le iniziali.
@MainActor
struct AuthorAvatarView: View {
    let name: String
    var photoPath: String? = nil
    var remoteURL: URL? = nil
    var size: CGFloat = 44

    @State private var storedImage: UIImage? = nil

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: CoverPlaceholderView.palette(for: name),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Text(initials)
                .font(.system(size: size * 0.36, weight: .semibold, design: .serif))
                .foregroundStyle(.white)

            if let storedImage {
                Image(uiImage: storedImage)
                    .resizable()
                    .scaledToFill()
            } else if photoPath == nil, let remoteURL {
                AsyncImage(url: remoteURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Color.clear
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .task(id: photoPath) {
            guard let photoPath else {
                storedImage = nil
                return
            }
            storedImage = await ImageStorageManager.shared.loadThumbnail(relativePath: photoPath, maxPixelSize: size * 3)
        }
        .accessibilityHidden(true)
    }

    private var initials: String {
        let words = name.split(separator: " ").filter { $0.first?.isLetter == true }
        let letters = [words.first, words.count > 1 ? words.last : nil].compactMap { $0?.first }
        return String(letters).uppercased()
    }
}

// MARK: - Autori della libreria

/// Autore presente nella libreria, con i conteggi dei suoi libri.
struct LibraryAuthor: Identifiable, Hashable {
    let key: String
    let name: String
    let bookCount: Int
    let readCount: Int
    let averageRating: Double?

    var id: String { key }

    /// Raggruppa gli autori di tutti i libri (i coautori contano per ciascuno).
    static func collect(from books: [BookItem]) -> [LibraryAuthor] {
        var groups: [String: (names: [String: Int], books: [BookItem])] = [:]
        for book in books {
            for name in book.authorList {
                let key = TextMatching.authorKey(name)
                guard !key.isEmpty else { continue }
                var group = groups[key] ?? (names: [:], books: [])
                group.names[name, default: 0] += 1
                group.books.append(book)
                groups[key] = group
            }
        }
        return groups.map { key, group in
            let displayName = group.names.max { $0.value < $1.value }?.key ?? key
            let rated = group.books.filter(\.isRated)
            return LibraryAuthor(
                key: key,
                name: displayName,
                bookCount: group.books.count,
                readCount: group.books.filter { $0.status == .read }.count,
                averageRating: rated.isEmpty ? nil : rated.reduce(0) { $0 + $1.rating } / Double(rated.count)
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

struct LibraryAuthorRow: View {
    let author: LibraryAuthor
    var photoPath: String?

    var body: some View {
        HStack(spacing: 14) {
            AuthorAvatarView(name: author.name, photoPath: photoPath, size: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(author.name)
                    .font(.headline)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Color.pbTextSecondary)
            }
            Spacer(minLength: 0)
            if let rating = author.averageRating {
                RatingStarsDisplay(rating: (rating * 2).rounded() / 2, size: 10)
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        let books = author.bookCount == 1 ? "1 libro" : "\(author.bookCount) libri"
        return author.readCount > 0 ? "\(books) · \(author.readCount) letti" : books
    }
}
