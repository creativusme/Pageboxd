import Foundation

// Sorgenti dei metadati. Ognuna converte le risposte del proprio catalogo in `BookMetadata`;
// l'unione e l'ordinamento dei risultati avvengono in `BookMetadataFetcher`.

// MARK: - SBN (Servizio Bibliotecario Nazionale)

/// Catalogo collettivo delle biblioteche italiane: copre praticamente tutti i libri pubblicati in Italia.
extension BookMetadataFetcher {
    private static let sbnBaseURL = "https://opac.sbn.it/opacmobilegw"

    func sbnLookup(isbn: String) async throws -> BookMetadata {
        // I libri catalogati prima del 2007 sono indicizzati solo con l'ISBN-10: si cercano entrambe le forme.
        let variants = ISBN.variants(of: isbn)
        let records = await withTaskGroup(of: [SBNRecord].self) { group in
            for variant in variants {
                group.addTask { (try? await self.sbnRecords(parameters: ["isbn": variant], rows: 5)) ?? [] }
            }
            var collected: [SBNRecord] = []
            for await batch in group {
                collected.append(contentsOf: batch)
            }
            return collected
        }

        guard let record = records.first(where: \.isBook) ?? records.first,
              var metadata = record.metadata(fallbackISBN: isbn)
        else { throw MetadataFetchError.notFound }
        metadata.isbn = isbn

        // La scheda completa aggiunge numero di pagine e lingua.
        if let identifier = record.codiceIdentificativo,
           let fullRecord = try? await sbnFullRecord(identifier: identifier) {
            metadata = fullRecord.enriching(metadata)
        }
        return metadata
    }

    func sbnSearch(text: String) async throws -> [BookMetadata] {
        let records = try await sbnRecords(parameters: ["any": text], rows: 30)
        return records.filter(\.isBook).compactMap { $0.metadata(fallbackISBN: nil) }
    }

    fileprivate func sbnRecords(parameters: [String: String], rows: Int) async throws -> [SBNRecord] {
        var query = parameters
        query["start"] = "0"
        query["rows"] = String(rows)
        let url = try Self.makeURL("\(Self.sbnBaseURL)/search.json", query: query)
        let response: SBNSearchResponse = try await getJSON(url)
        return response.briefRecords ?? []
    }

    fileprivate func sbnFullRecord(identifier: String) async throws -> SBNRecord {
        let url = try Self.makeURL("\(Self.sbnBaseURL)/full.json", query: ["bid": identifier])
        return try await getJSON(url)
    }
}

private struct SBNSearchResponse: Decodable {
    let briefRecords: [SBNRecord]?
}

private struct SBNRecord: Decodable {
    let codiceIdentificativo: String?
    let isbn: String?
    let autorePrincipale: String?
    let titolo: String?
    let pubblicazione: String?
    let descrizioneFisica: String?
    let linguaPubblicazione: String?
    let numeri: [String]?
    let tipo: String?
    let livello: String?

    var isBook: Bool {
        let type = TextMatching.folded(tipo ?? "testo a stampa")
        let level = TextMatching.folded(livello ?? "monografia")
        return type.contains("testo") && !level.contains("periodic") && !level.contains("spoglio")
    }

    func metadata(fallbackISBN: String?) -> BookMetadata? {
        guard let rawTitle = titolo?.nilIfBlank else { return nil }
        let parsed = SBNParsing.title(rawTitle)
        guard !parsed.title.isEmpty else { return nil }

        let recordISBN = isbn.flatMap { ISBN.normalize($0) }
            ?? numeri?.lazy.compactMap { SBNParsing.isbn(fromNumber: $0) }.first
        let finalISBN = recordISBN ?? fallbackISBN
        let language = SBNParsing.languageCode(linguaPubblicazione)
            ?? finalISBN.flatMap { ISBN.isItalian($0) ? "it" : nil }

        return BookMetadata(
            id: "sbn-\(codiceIdentificativo ?? rawTitle)",
            isbn: finalISBN,
            title: parsed.title,
            authors: SBNParsing.authors(principal: autorePrincipale, responsibility: parsed.responsibility),
            publicationYear: MetadataParsing.lastYear(in: pubblicazione),
            pageCount: MetadataParsing.pages(fromPhysicalDescription: descrizioneFisica),
            synopsis: nil,
            coverURL: nil,
            languageCode: language,
            source: .sbn,
            publisher: SBNParsing.publisher(pubblicazione)
        )
    }

    func enriching(_ metadata: BookMetadata) -> BookMetadata {
        var result = metadata
        if result.pageCount == nil {
            result.pageCount = MetadataParsing.pages(fromPhysicalDescription: descrizioneFisica)
        }
        if let language = SBNParsing.languageCode(linguaPubblicazione) {
            result.languageCode = language
        }
        if result.publisher == nil {
            result.publisher = SBNParsing.publisher(pubblicazione)
        }
        if result.publicationYear == nil {
            result.publicationYear = MetadataParsing.lastYear(in: pubblicazione)
        }
        return result
    }
}

private enum SBNParsing {
    static let genericSubtitles: Set<String> = [
        "romanzo", "romanzi", "racconti", "racconto", "poesie", "saggio", "saggi",
        "novella", "novelle", "fiaba", "fiabe", "novel", "a novel", "romanzo storico", "romanzo giallo"
    ]

    /// "Vita di Pi  =  Life of Pi / Yann Martel ; traduzione di …" → ("Vita di Pi", "Yann Martel ; traduzione di …").
    static func title(_ raw: String) -> (title: String, responsibility: String?) {
        let collapsed = MetadataParsing.collapsedWhitespace(raw.replacingOccurrences(of: "*", with: ""))
        var parts = collapsed.components(separatedBy: " / ")
        var title = parts.removeFirst()
        let responsibility = parts.first?.trimmed

        if let parallel = title.range(of: " = ") {
            title = String(title[..<parallel.lowerBound])
        }
        if let colon = title.range(of: " : ", options: .backwards) {
            let subtitle = TextMatching.folded(String(title[colon.upperBound...])).trimmed
            if genericSubtitles.contains(subtitle) {
                title = String(title[..<colon.lowerBound])
            }
        }
        title = title.replacingOccurrences(of: #"[\[\]]"#, with: "", options: .regularExpression).trimmed
        return (MetadataParsing.capitalizedFirstLetter(title), responsibility)
    }

    /// Autori dalla dichiarazione di responsabilità ("Douglas Preston, Lincoln Child ; trad. …"),
    /// altrimenti dall'autore principale in forma catalografica ("Martel, Yann").
    static func authors(principal: String?, responsibility: String?) -> [String] {
        if var statement = responsibility?.components(separatedBy: " ; ").first?.trimmed, !statement.isEmpty {
            statement = statement.replacingOccurrences(of: #"[\[\]]"#, with: "", options: .regularExpression).trimmed
            let folded = TextMatching.folded(statement)
            let prefixes = ["di ", "testo di ", "testi di ", "scritto da ", "by "]
            if let prefix = prefixes.first(where: { folded.hasPrefix($0) }) {
                statement = String(statement.dropFirst(prefix.count)).trimmed
            }
            let excluded = ["a cura", "cura di", "traduz", "tradott", "illustra", "introduz", "prefaz", "edited", "translated"]
            if !excluded.contains(where: { folded.contains($0) }) {
                let names = statement
                    .replacingOccurrences(of: " e ", with: ", ")
                    .replacingOccurrences(of: " and ", with: ", ")
                    .replacingOccurrences(of: " & ", with: ", ")
                    .components(separatedBy: ", ")
                    .map { $0.trimmed }
                    .filter { !$0.isEmpty }
                if !names.isEmpty, names.count <= 6,
                   names.allSatisfy({ (1...5).contains($0.split(separator: " ").count) }) {
                    return names
                }
            }
        }
        if let principal = principal?.nilIfBlank {
            return [MetadataParsing.personName(fromCatalogForm: principal)]
        }
        return []
    }

    /// "Casale Monferrato : Piemme, 2003" → "Piemme".
    static func publisher(_ publication: String?) -> String? {
        guard let publication else { return nil }
        let first = publication.components(separatedBy: " ; ").first ?? publication
        guard let colon = first.range(of: " : ") else { return nil }
        var name = String(first[colon.upperBound...])
        if let comma = name.range(of: ",", options: .backwards) {
            name = String(name[..<comma.lowerBound])
        }
        return name.replacingOccurrences(of: #"[\[\]]"#, with: "", options: .regularExpression).nilIfBlank
    }

    static func isbn(fromNumber value: String) -> String? {
        guard value.uppercased().contains("ISBN") else { return nil }
        return ISBN.normalize(value)
    }

    static func languageCode(_ value: String?) -> String? {
        guard let value = value?.nilIfBlank else { return nil }
        let map = [
            "ITALIANO": "it", "INGLESE": "en", "FRANCESE": "fr", "TEDESCO": "de", "SPAGNOLO": "es",
            "PORTOGHESE": "pt", "LATINO": "la", "GRECO": "el", "RUSSO": "ru", "GIAPPONESE": "ja",
            "CINESE": "zh", "ARABO": "ar", "OLANDESE": "nl", "SVEDESE": "sv", "POLACCO": "pl", "CATALANO": "ca"
        ]
        return map[value.uppercased()]
    }
}

// MARK: - Open Library

extension BookMetadataFetcher {
    private static let openLibrarySearchFields = [
        "key", "title", "author_name", "first_publish_year", "number_of_pages_median", "cover_i", "language",
        "editions", "editions.key", "editions.title", "editions.language", "editions.isbn",
        "editions.cover_i", "editions.publisher"
    ].joined(separator: ",")

    func openLibraryLookup(isbn: String) async throws -> BookMetadata {
        let url = try Self.makeURL(
            "https://openlibrary.org/search.json",
            query: ["q": "isbn:\(isbn)", "limit": "1", "fields": Self.openLibrarySearchFields]
        )
        let response: OpenLibrarySearchResponse = try await getJSON(url)
        guard let metadata = response.docs.first?.metadata(knownISBN: isbn) else {
            throw MetadataFetchError.notFound
        }
        return metadata
    }

    /// Con `lang` Open Library restituisce, per ogni opera, l'edizione nella lingua richiesta
    /// ("vita di pi" → edizione italiana "Vita di Pi" invece di "Life of Pi").
    func openLibrarySearch(query: String, language: String) async throws -> [BookMetadata] {
        let url = try Self.makeURL(
            "https://openlibrary.org/search.json",
            query: ["q": query, "lang": language, "limit": "20", "fields": Self.openLibrarySearchFields]
        )
        let response: OpenLibrarySearchResponse = try await getJSON(url)
        return response.docs.compactMap { $0.metadata(knownISBN: nil) }
    }

    /// Opere di un autore, con l'edizione nella lingua richiesta quando esiste.
    func openLibraryWorks(authorKey: String?, authorName: String, language: String) async throws -> [BookMetadata] {
        let query = authorKey.map { "author_key:\($0)" } ?? "author:\"\(authorName)\""
        let url = try Self.makeURL(
            "https://openlibrary.org/search.json",
            query: [
                "q": query,
                "lang": language,
                "sort": "editions",
                "limit": "60",
                "fields": Self.openLibrarySearchFields
            ]
        )
        let response: OpenLibrarySearchResponse = try await getJSON(url)
        return response.docs.compactMap { $0.metadata(knownISBN: nil) }
    }

    /// Trama dell'opera (in inglese per la maggior parte dei libri).
    func openLibraryDescription(workKey: String) async throws -> String? {
        guard workKey.hasPrefix("/works/") else { return nil }
        let url = try Self.makeURL("https://openlibrary.org\(workKey).json", query: [:])
        let work: OpenLibraryWork = try await getJSON(url)
        return MetadataParsing.cleanDescription(work.description?.value)
    }

    static func openLibraryCoverURL(isbn: String) -> URL? {
        URL(string: "https://covers.openlibrary.org/b/isbn/\(isbn)-L.jpg?default=false")
    }

    static func openLibraryLanguage(_ code: String?) -> String? {
        guard let code = code?.lowercased().nilIfBlank else { return nil }
        let map = [
            "ita": "it", "eng": "en", "fre": "fr", "fra": "fr", "ger": "de", "deu": "de", "spa": "es",
            "por": "pt", "lat": "la", "gre": "el", "rus": "ru", "jpn": "ja", "chi": "zh", "dut": "nl"
        ]
        if let mapped = map[code] { return mapped }
        return code.count == 2 ? code : nil
    }
}

private struct OpenLibrarySearchResponse: Decodable {
    let docs: [OpenLibrarySearchDoc]
}

private struct OpenLibrarySearchDoc: Decodable {
    let key: String?
    let title: String?
    let authorName: [String]?
    let firstPublishYear: Int?
    let numberOfPagesMedian: Int?
    let coverId: Int?
    let language: [String]?
    let editions: OpenLibraryEditions?

    enum CodingKeys: String, CodingKey {
        case key
        case title
        case authorName = "author_name"
        case firstPublishYear = "first_publish_year"
        case numberOfPagesMedian = "number_of_pages_median"
        case coverId = "cover_i"
        case language
        case editions
    }

    func metadata(knownISBN: String?) -> BookMetadata? {
        let edition = editions?.docs.first
        guard let title = edition?.title?.nilIfBlank ?? title?.nilIfBlank else { return nil }

        // L'elenco ISBN dell'opera contiene tutte le edizioni del mondo: si usa solo quello dell'edizione scelta.
        let editionISBN = edition?.isbn?.lazy.compactMap { ISBN.normalize($0) }.first
        let finalISBN = knownISBN ?? editionISBN
        let cover = (edition?.coverId ?? coverId).flatMap { URL(string: "https://covers.openlibrary.org/b/id/\($0)-L.jpg") }
            ?? finalISBN.flatMap { BookMetadataFetcher.openLibraryCoverURL(isbn: $0) }
        let workLanguage = (language?.count == 1) ? language?.first : nil
        let languageCode = BookMetadataFetcher.openLibraryLanguage(edition?.language?.first ?? workLanguage)

        var metadata = BookMetadata(
            id: "openlibrary-\(edition?.key ?? key ?? UUID().uuidString)",
            isbn: finalISBN,
            title: title,
            authors: (authorName ?? []).compactMap { $0.nilIfBlank },
            publicationYear: firstPublishYear,
            pageCount: numberOfPagesMedian.flatMap { $0 > 0 ? $0 : nil },
            synopsis: nil,
            coverURL: cover,
            languageCode: languageCode,
            source: .openLibrary,
            publisher: edition?.publisher?.first?.nilIfBlank
        )
        metadata.openLibraryWorkKey = key
        return metadata
    }
}

private struct OpenLibraryEditions: Decodable {
    let docs: [OpenLibraryEditionDoc]
}

private struct OpenLibraryEditionDoc: Decodable {
    let key: String?
    let title: String?
    let language: [String]?
    let isbn: [String]?
    let coverId: Int?
    let publisher: [String]?

    enum CodingKeys: String, CodingKey {
        case key
        case title
        case language
        case isbn
        case coverId = "cover_i"
        case publisher
    }
}

private struct OpenLibraryWork: Decodable {
    let description: OpenLibraryText?
}

/// Open Library restituisce le descrizioni sia come stringa semplice sia come `{ "type": ..., "value": ... }`.
private struct OpenLibraryText: Decodable {
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

// MARK: - Apple Books

/// Catalogo pubblico di Apple Books: titoli nella lingua del negozio scelto, copertine di qualità e trame.
extension BookMetadataFetcher {
    func appleBooksSearch(
        term: String,
        language: String,
        limit: Int = 25,
        authorOnly: Bool = false
    ) async throws -> [BookMetadata] {
        let store = Self.appleStore(for: language)
        var query = [
            "term": term,
            "media": "ebook",
            "entity": "ebook",
            "country": store.country,
            "lang": store.locale,
            "limit": String(limit)
        ]
        if authorOnly {
            query["attribute"] = "authorTerm"
        }
        let url = try Self.makeURL("https://itunes.apple.com/search", query: query)
        let response: ITunesResponse = try await getJSON(url)
        return response.results.compactMap { $0.metadata() }
    }

    /// Ricerca diretta per ISBN (trova soprattutto le edizioni digitali).
    func appleBooksLookup(isbn: String) async throws -> BookMetadata {
        let country = ISBN.isItalian(isbn) ? "IT" : "US"
        let url = try Self.makeURL("https://itunes.apple.com/lookup", query: ["isbn": isbn, "country": country])
        let response: ITunesResponse = try await getJSON(url)
        guard var metadata = response.results.lazy.compactMap({ $0.metadata() }).first else {
            throw MetadataFetchError.notFound
        }
        metadata.isbn = isbn
        return metadata
    }

    /// Cerca lo stesso libro su Apple Books per completare copertina e trama.
    func appleBooksMatch(title: String, author: String?, language: String) async throws -> BookMetadata {
        let term = [title, author].compactMap { $0?.nilIfBlank }.joined(separator: " ")
        let candidates = try await appleBooksSearch(term: term, language: language, limit: 10)
        let titleKey = TextMatching.titleKey(title)
        let surname = TextMatching.surnameKey(author)

        let match = candidates.first { candidate in
            let sameTitle = TextMatching.titleKey(candidate.title) == titleKey
                || TextMatching.relevance(query: title, title: candidate.title, authors: []) >= 0.95
            let sameAuthor = surname.isEmpty
                || candidate.authors.contains { TextMatching.tokens($0).contains(surname) }
            return sameTitle && sameAuthor
        }
        guard let match else { throw MetadataFetchError.notFound }
        return match
    }

    private static func appleStore(for language: String) -> (country: String, locale: String) {
        switch language {
        case "en": return ("US", "en_us")
        case "fr": return ("FR", "fr_fr")
        case "es": return ("ES", "es_es")
        case "de": return ("DE", "de_de")
        case "pt": return ("PT", "pt_pt")
        default: return ("IT", "it_it")
        }
    }
}

private struct ITunesResponse: Decodable {
    let results: [ITunesItem]
}

private struct ITunesItem: Decodable {
    let trackId: Int?
    let trackName: String?
    let artistName: String?
    let description: String?
    let artworkUrl100: String?
    let kind: String?

    func metadata() -> BookMetadata? {
        guard let title = trackName?.nilIfBlank, kind == nil || kind == "ebook" else { return nil }
        let synopsis = MetadataParsing.cleanDescription(description)
        let sample = [title, synopsis.map { String($0.prefix(400)) }].compactMap { $0 }.joined(separator: ". ")

        return BookMetadata(
            id: "apple-\(trackId.map { String($0) } ?? UUID().uuidString)",
            isbn: nil,
            title: title,
            authors: Self.authors(from: artistName),
            // La data di Apple è quella dell'ebook, non della prima pubblicazione: meglio non usarla.
            publicationYear: nil,
            pageCount: nil,
            synopsis: synopsis,
            coverURL: artworkUrl100.flatMap { URL(string: $0.replacingOccurrences(of: "100x100bb", with: "600x600bb")) },
            languageCode: TextMatching.detectLanguage(of: sample, minimumConfidence: 0.5),
            source: .appleBooks,
            thumbnailURL: artworkUrl100.flatMap { URL(string: $0.replacingOccurrences(of: "100x100bb", with: "200x200bb")) }
        )
    }

    private static func authors(from artist: String?) -> [String] {
        guard let artist = artist?.nilIfBlank else { return [] }
        return artist
            .replacingOccurrences(of: " & ", with: ", ")
            .components(separatedBy: ", ")
            .map { $0.trimmed }
            .filter { !$0.isEmpty }
    }
}

// MARK: - Google Books

extension BookMetadataFetcher {
    private static let googleFields = "items(id,volumeInfo(title,authors,publisher,publishedDate,description,pageCount,industryIdentifiers,imageLinks,language))"

    func googleLookup(isbn: String) async throws -> BookMetadata {
        let url = try googleURL(query: ["q": "isbn:\(isbn)"])
        let response: GoogleVolumesResponse = try await googleRequest(url)
        guard let metadata = response.items?.lazy.compactMap({ $0.metadata(fallbackISBN: isbn) }).first else {
            throw MetadataFetchError.notFound
        }
        return metadata
    }

    func googleSearch(query: String, language: String) async throws -> [BookMetadata] {
        var parameters = ["q": query, "maxResults": "20", "printType": "books"]
        if ["it", "en", "fr", "de", "es", "pt"].contains(language) {
            parameters["langRestrict"] = language
        }
        let url = try googleURL(query: parameters)
        let response: GoogleVolumesResponse = try await googleRequest(url)
        return (response.items ?? []).compactMap { $0.metadata(fallbackISBN: nil) }
    }

    private func googleURL(query: [String: String]) throws -> URL {
        var parameters = query
        parameters["country"] = "IT"
        parameters["fields"] = Self.googleFields
        if let key = googleAPIKey {
            parameters["key"] = key
        }
        return try Self.makeURL("https://www.googleapis.com/books/v1/volumes", query: parameters)
    }

    /// Senza chiave Google limita molto le richieste: al primo rifiuto la sorgente viene sospesa per un'ora.
    private func googleRequest<T: Decodable>(_ url: URL) async throws -> T {
        do {
            return try await getJSON(url)
        } catch MetadataFetchError.serviceUnavailable {
            markGoogleUnavailable()
            throw MetadataFetchError.serviceUnavailable
        }
    }
}

private struct GoogleVolumesResponse: Decodable {
    let items: [GoogleVolume]?
}

private struct GoogleVolume: Decodable {
    let id: String
    let volumeInfo: GoogleVolumeInfo

    func metadata(fallbackISBN: String?) -> BookMetadata? {
        guard let title = volumeInfo.title?.nilIfBlank else { return nil }
        let identifiers = volumeInfo.industryIdentifiers ?? []
        let isbn13 = identifiers.first { $0.type == "ISBN_13" }.flatMap { ISBN.normalize($0.identifier) }
        let isbn10 = identifiers.first { $0.type == "ISBN_10" }.flatMap { ISBN.normalize($0.identifier) }
        let links = volumeInfo.imageLinks
        let cover = links?.large ?? links?.medium ?? links?.small ?? links?.thumbnail ?? links?.smallThumbnail

        return BookMetadata(
            id: "google-\(id)",
            isbn: isbn13 ?? isbn10 ?? fallbackISBN,
            title: title,
            authors: (volumeInfo.authors ?? []).compactMap { $0.nilIfBlank },
            publicationYear: MetadataParsing.year(from: volumeInfo.publishedDate),
            pageCount: volumeInfo.pageCount.flatMap { $0 > 0 ? $0 : nil },
            synopsis: MetadataParsing.cleanDescription(volumeInfo.description),
            coverURL: MetadataParsing.secureURL(cover),
            languageCode: volumeInfo.language.map { String($0.prefix(2)).lowercased() },
            source: .googleBooks,
            publisher: volumeInfo.publisher?.nilIfBlank,
            thumbnailURL: MetadataParsing.secureURL(links?.thumbnail ?? links?.smallThumbnail)
        )
    }
}

private struct GoogleVolumeInfo: Decodable {
    let title: String?
    let authors: [String]?
    let publisher: String?
    let publishedDate: String?
    let description: String?
    let pageCount: Int?
    let industryIdentifiers: [GoogleIndustryIdentifier]?
    let imageLinks: GoogleImageLinks?
    let language: String?
}

private struct GoogleIndustryIdentifier: Decodable {
    let type: String
    let identifier: String
}

private struct GoogleImageLinks: Decodable {
    let smallThumbnail: String?
    let thumbnail: String?
    let small: String?
    let medium: String?
    let large: String?
}
