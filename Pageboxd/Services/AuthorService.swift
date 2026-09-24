import Foundation
import UIKit

/// Autore trovato nella ricerca online.
struct AuthorSearchResult: Identifiable, Hashable, Sendable {
    let name: String
    let openLibraryKey: String?
    let birthDate: String?
    let deathDate: String?
    let topWork: String?
    let workCount: Int?

    var id: String { openLibraryKey ?? TextMatching.authorKey(name) }

    var photoURL: URL? {
        openLibraryKey.flatMap { URL(string: "https://covers.openlibrary.org/a/olid/\($0)-M.jpg?default=false") }
    }

    var route: AuthorRoute { AuthorRoute(name: name, openLibraryKey: openLibraryKey) }
}

/// Dati di un autore uniti da Wikipedia (italiana, poi inglese) e Open Library.
struct AuthorDetails: Sendable {
    var name: String
    var openLibraryKey: String?
    var summary: String?
    var bio: String?
    var bioSource: String?
    var sourceURL: URL?
    var birthDate: String?
    var deathDate: String?
    var photoURL: URL?
}

final class AuthorService: @unchecked Sendable {
    static let shared = AuthorService()

    private var fetcher: BookMetadataFetcher { .shared }
    private let worksCache: NSCache<NSString, AuthorWorksBox> = {
        let cache = NSCache<NSString, AuthorWorksBox>()
        cache.countLimit = 50
        return cache
    }()

    /// Parole che nella descrizione di Wikipedia indicano uno scrittore (per evitare omonimi).
    private static let writerHints = [
        "scrittor", "autor", "romanzier", "poet", "saggist", "giornalist", "fumettist", "drammaturg",
        "filosof", "storic", "sceneggiator", "illustrat", "divulgat", "linguist", "teolog", "critic",
        "writer", "novelist", "author", "journalist", "cartoonist", "playwright", "philosopher", "historian", "essayist"
    ]

    // MARK: Ricerca

    func searchAuthors(_ query: String) async throws -> [AuthorSearchResult] {
        let trimmed = query.trimmed
        guard trimmed.count >= 2 else { return [] }
        let url = try BookMetadataFetcher.makeURL(
            "https://openlibrary.org/search/authors.json",
            query: ["q": trimmed, "limit": "20"]
        )
        let response: OpenLibraryAuthorSearch = try await fetcher.getJSON(url)
        return response.docs
            .compactMap { doc -> AuthorSearchResult? in
                guard let name = doc.name?.nilIfBlank else { return nil }
                return AuthorSearchResult(
                    name: name,
                    openLibraryKey: doc.key.map { $0.replacingOccurrences(of: "/authors/", with: "") },
                    birthDate: doc.birthDate,
                    deathDate: doc.deathDate,
                    topWork: doc.topWork,
                    workCount: doc.workCount
                )
            }
            .sorted { ($0.workCount ?? 0) > ($1.workCount ?? 0) }
    }

    // MARK: Scheda autore

    func details(for name: String, openLibraryKey: String?) async throws -> AuthorDetails {
        let wikipediaTask = Task { await self.wikipediaArticle(for: name) }
        let openLibraryTask = Task { () -> OpenLibraryAuthor? in
            guard let key = try? await self.resolveOpenLibraryKey(name: name, known: openLibraryKey) else { return nil }
            return try? await self.openLibraryAuthor(key: key)
        }

        let (article, author) = await withTaskCancellationHandler {
            (await wikipediaTask.value, await openLibraryTask.value)
        } onCancel: {
            wikipediaTask.cancel()
            openLibraryTask.cancel()
        }

        guard article != nil || author != nil else { throw MetadataFetchError.notFound }

        var details = AuthorDetails(name: name, openLibraryKey: author?.key ?? openLibraryKey)
        details.summary = article?.description.map { MetadataParsing.capitalizedFirstLetter($0) }
        details.birthDate = author?.birthDate
        details.deathDate = author?.deathDate

        if let article, let extract = article.extract {
            details.bio = extract
            details.bioSource = "Wikipedia"
            details.sourceURL = article.url
        } else if let bio = author?.bio {
            details.bio = bio
            details.bioSource = "Open Library"
            details.sourceURL = author?.key.flatMap { URL(string: "https://openlibrary.org/authors/\($0)") }
        }
        details.photoURL = article?.imageURL ?? author?.photoURL
        return details
    }

    func downloadPhoto(from url: URL) async throws -> UIImage {
        try await fetcher.downloadCover(from: url)
    }

    // MARK: Bibliografia

    /// Opere dell'autore: Open Library (bibliografia completa) + Apple Books (titoli delle edizioni italiane).
    func works(for name: String, openLibraryKey: String?) async -> [BookMetadata] {
        let cacheKey = TextMatching.authorKey(name) as NSString
        if let cached = worksCache.object(forKey: cacheKey) {
            return cached.works
        }

        let surname = TextMatching.surnameKey(name)
        let openLibraryTask = Task { () -> [BookMetadata] in
            let key = try? await self.resolveOpenLibraryKey(name: name, known: openLibraryKey)
            return (try? await self.fetcher.openLibraryWorks(authorKey: key, authorName: name, language: "it")) ?? []
        }
        let appleTask = Task { () -> [BookMetadata] in
            let results = (try? await self.fetcher.appleBooksSearch(term: name, language: "it", limit: 60, authorOnly: true)) ?? []
            // Solo edizioni italiane in cui l'autore compare davvero (niente antologie con decine di nomi).
            return results.filter { item in
                item.languageCode == "it"
                    && item.authors.count <= 3
                    && item.authors.contains { TextMatching.tokens($0).contains(surname) }
            }
        }

        let (openLibrary, apple) = await withTaskCancellationHandler {
            (await openLibraryTask.value, await appleTask.value)
        } onCancel: {
            openLibraryTask.cancel()
            appleTask.cancel()
        }

        var merged: [BookMetadata] = []
        var indexByTitle: [String: Int] = [:]
        for item in openLibrary + apple {
            let key = TextMatching.titleKey(item.title)
            guard !key.isEmpty else { continue }
            if let index = indexByTitle[key] {
                merged[index] = merged[index].filling(from: item)
            } else {
                indexByTitle[key] = merged.count
                merged.append(item)
            }
        }
        let sorted = merged.sorted { lhs, rhs in
            switch (lhs.publicationYear, rhs.publicationYear) {
            case let (left?, right?): return left > right
            case (.some, nil): return true
            case (nil, .some): return false
            default: return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        }
        if !sorted.isEmpty {
            worksCache.setObject(AuthorWorksBox(works: sorted), forKey: cacheKey)
        }
        return sorted
    }

    // MARK: Open Library

    private func resolveOpenLibraryKey(name: String, known: String?) async throws -> String? {
        if let known { return known }
        let url = try BookMetadataFetcher.makeURL(
            "https://openlibrary.org/search/authors.json",
            query: ["q": name, "limit": "5"]
        )
        let response: OpenLibraryAuthorSearch = try await fetcher.getJSON(url)
        let target = TextMatching.authorKey(name)
        let match = response.docs
            .filter { TextMatching.authorKey($0.name ?? "") == target }
            .max { ($0.workCount ?? 0) < ($1.workCount ?? 0) }
        return match?.key.map { $0.replacingOccurrences(of: "/authors/", with: "") }
    }

    private func openLibraryAuthor(key: String) async throws -> OpenLibraryAuthor {
        let url = try BookMetadataFetcher.makeURL("https://openlibrary.org/authors/\(key).json", query: [:])
        let record: OpenLibraryAuthorRecord = try await fetcher.getJSON(url)
        let hasPhoto = (record.photos ?? []).contains { $0 > 0 }
        return OpenLibraryAuthor(
            key: key,
            bio: MetadataParsing.cleanDescription(record.bio?.value),
            birthDate: record.birthDate,
            deathDate: record.deathDate,
            photoURL: hasPhoto ? URL(string: "https://covers.openlibrary.org/a/olid/\(key)-L.jpg?default=false") : nil
        )
    }

    // MARK: Wikipedia

    private func wikipediaArticle(for name: String) async -> WikipediaArticle? {
        for language in ["it", "en"] {
            if let article = try? await wikipediaArticle(for: name, language: language) {
                return article
            }
        }
        return nil
    }

    private func wikipediaArticle(for name: String, language: String) async throws -> WikipediaArticle? {
        let api = "https://\(language).wikipedia.org/w/api.php"
        let searchURL = try BookMetadataFetcher.makeURL(api, query: [
            "action": "query", "list": "search", "srsearch": name, "srlimit": "6",
            "format": "json", "formatversion": "2"
        ])
        let search: WikiSearchResponse = try await fetcher.getJSON(searchURL)

        // Solo voci con lo stesso nome (ignorando l'ordine e le precisazioni tra parentesi).
        let target = TextMatching.authorKey(name)
        let candidates = (search.query?.search ?? [])
            .map(\.title)
            .filter { TextMatching.authorKey(Self.withoutParentheses($0)) == target }
            .prefix(3)

        var fallback: WikipediaArticle?
        for title in candidates {
            guard let article = try await wikipediaPage(title: title, api: api) else { continue }
            let description = TextMatching.folded(article.description ?? "")
            if Self.writerHints.contains(where: { description.contains($0) }) {
                return article
            }
            if fallback == nil, article.description == nil {
                fallback = article
            }
        }
        return fallback
    }

    private func wikipediaPage(title: String, api: String) async throws -> WikipediaArticle? {
        let url = try BookMetadataFetcher.makeURL(api, query: [
            "action": "query",
            "prop": "extracts|pageimages|description|info",
            "inprop": "url",
            "explaintext": "1",
            "exsectionformat": "plain",
            "piprop": "thumbnail",
            "pithumbsize": "600",
            "redirects": "1",
            "format": "json",
            "formatversion": "2",
            "titles": title
        ])
        let response: WikiPageResponse = try await fetcher.getJSON(url)
        guard let page = response.query?.pages.first, page.missing != true else { return nil }
        return WikipediaArticle(
            title: page.title,
            description: page.description?.nilIfBlank,
            extract: Self.biography(from: page.extract),
            imageURL: page.thumbnail.flatMap { URL(string: $0.source) },
            url: page.fullurl.flatMap { URL(string: $0) }
        )
    }

    /// Primi paragrafi della voce (circa 2.000 caratteri), senza i titoli delle sezioni.
    static func biography(from extract: String?) -> String? {
        guard let extract else { return nil }
        var paragraphs: [String] = []
        var length = 0
        for line in extract.components(separatedBy: "\n") {
            let paragraph = line.trimmed
            // Le righe brevi senza punteggiatura finale sono titoli di sezione ("Biografia", "Opere").
            guard paragraph.count >= 40 || paragraph.hasSuffix(".") else { continue }
            paragraphs.append(paragraph)
            length += paragraph.count
            if length >= 1_800 { break }
        }
        return paragraphs.joined(separator: "\n\n").nilIfBlank
    }

    private static func withoutParentheses(_ title: String) -> String {
        title.replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
    }
}

// MARK: - Tipi di supporto

private final class AuthorWorksBox {
    let works: [BookMetadata]

    init(works: [BookMetadata]) {
        self.works = works
    }
}

private struct OpenLibraryAuthor: Sendable {
    let key: String?
    let bio: String?
    let birthDate: String?
    let deathDate: String?
    let photoURL: URL?
}

private struct WikipediaArticle: Sendable {
    let title: String
    let description: String?
    let extract: String?
    let imageURL: URL?
    let url: URL?
}

private struct OpenLibraryAuthorSearch: Decodable {
    let docs: [Doc]

    struct Doc: Decodable {
        let key: String?
        let name: String?
        let birthDate: String?
        let deathDate: String?
        let topWork: String?
        let workCount: Int?

        enum CodingKeys: String, CodingKey {
            case key
            case name
            case birthDate = "birth_date"
            case deathDate = "death_date"
            case topWork = "top_work"
            case workCount = "work_count"
        }
    }
}

private struct OpenLibraryAuthorRecord: Decodable {
    let bio: AuthorBioText?
    let birthDate: String?
    let deathDate: String?
    let photos: [Int]?

    enum CodingKeys: String, CodingKey {
        case bio
        case birthDate = "birth_date"
        case deathDate = "death_date"
        case photos
    }
}

/// La biografia arriva come stringa o come `{ "type": ..., "value": ... }`.
private struct AuthorBioText: Decodable {
    let value: String

    private enum CodingKeys: String, CodingKey {
        case value
    }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let string = try? single.decode(String.self) {
            value = string
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = try container.decode(String.self, forKey: .value)
    }
}

private struct WikiSearchResponse: Decodable {
    let query: Query?

    struct Query: Decodable {
        let search: [Item]
    }

    struct Item: Decodable {
        let title: String
    }
}

private struct WikiPageResponse: Decodable {
    let query: Query?

    struct Query: Decodable {
        let pages: [Page]
    }

    struct Page: Decodable {
        let title: String
        let missing: Bool?
        let description: String?
        let extract: String?
        let thumbnail: Thumbnail?
        let fullurl: String?
    }

    struct Thumbnail: Decodable {
        let source: String
    }
}
