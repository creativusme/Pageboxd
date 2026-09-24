import Foundation
import UIKit

/// Aggiornamento progressivo di una ricerca: i risultati arrivano man mano che rispondono i cataloghi.
struct SearchUpdate: Sendable {
    let results: [BookMetadata]
    let isFinal: Bool
}

/// Recupera i metadati da più cataloghi pubblici interrogati in parallelo:
/// biblioteche italiane (SBN), Open Library, Apple Books e Google Books.
/// Nessun dato personale viene inviato: solo l'ISBN o il testo cercato.
final class BookMetadataFetcher: @unchecked Sendable {
    static let shared = BookMetadataFetcher()

    let session: URLSession
    private let cache: NSCache<NSString, CachedResults> = {
        let cache = NSCache<NSString, CachedResults>()
        cache.countLimit = 200
        return cache
    }()
    private let googleLock = NSLock()
    private var googleSuspendedUntil: Date?

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 10
            configuration.timeoutIntervalForResource = 20
            configuration.waitsForConnectivity = false
            configuration.httpMaximumConnectionsPerHost = 6
            configuration.httpAdditionalHeaders = [
                "User-Agent": "Pageboxd/1.3 (iOS; personal reading journal)",
                "Accept": "application/json"
            ]
            self.session = URLSession(configuration: configuration)
        }
    }

    // MARK: Google Books

    /// Chiave facoltativa inserita dall'utente nelle Impostazioni.
    var googleAPIKey: String? {
        UserDefaults.standard.string(forKey: AppStorageKeys.googleBooksAPIKey)?.nilIfBlank
    }

    var isGoogleAvailable: Bool {
        if googleAPIKey != nil { return true }
        googleLock.lock()
        defer { googleLock.unlock() }
        guard let until = googleSuspendedUntil else { return true }
        return until < Date()
    }

    func markGoogleUnavailable() {
        guard googleAPIKey == nil else { return }
        googleLock.lock()
        googleSuspendedUntil = Date().addingTimeInterval(3600)
        googleLock.unlock()
    }

    // MARK: Ricerca per ISBN

    func fetch(isbn rawISBN: String) async throws -> BookMetadata {
        guard let isbn = ISBN.normalize(rawISBN) else { throw MetadataFetchError.invalidISBN }
        let cacheKey = "isbn:\(isbn)" as NSString
        if let cached = cache.object(forKey: cacheKey)?.results.first {
            return cached
        }

        var jobs: [(BookMetadata.Source, @Sendable () async throws -> BookMetadata)] = [
            (.sbn, { try await self.sbnLookup(isbn: isbn) }),
            (.openLibrary, { try await self.openLibraryLookup(isbn: isbn) }),
            (.appleBooks, { try await self.appleBooksLookup(isbn: isbn) })
        ]
        if isGoogleAvailable {
            jobs.append((.googleBooks, { try await self.googleLookup(isbn: isbn) }))
        }

        // Si attende al massimo 2,5 secondi dopo la prima risposta utile: abbastanza per unire
        // i dati dei cataloghi più lenti senza far aspettare quando uno ha già risposto.
        let outcome = await collect(jobs, timeout: 9, grace: 2.5)
        let language = ISBN.isItalian(isbn) ? "it" : Self.isbnLanguageGuess(isbn)
        let ordered = Self.sourceOrder(for: language).compactMap { outcome.results[$0] }

        guard var metadata = ordered.first else {
            throw Self.resolve(outcome.errors)
        }
        for other in ordered.dropFirst() {
            metadata = metadata.filling(from: other)
        }
        metadata.isbn = isbn
        metadata = await completed(metadata, isbn: isbn)

        cache.setObject(CachedResults(results: [metadata]), forKey: cacheKey)
        return metadata
    }

    /// Completa copertina e trama con tempi di attesa limitati.
    private func completed(_ base: BookMetadata, isbn: String) async -> BookMetadata {
        var result = base
        let title = result.title
        let author = result.authors.first
        let language = result.languageCode ?? (ISBN.isItalian(isbn) ? "it" : TextMatching.preferredLanguage)

        if result.coverURL == nil || result.synopsis == nil,
           let apple = try? await Self.withTimeout(3, { try await self.appleBooksMatch(title: title, author: author, language: language) }) {
            result = result.filling(from: apple)
        }
        // La trama di Open Library è quasi sempre in inglese: la si usa solo per libri non italiani.
        if result.synopsis == nil, language != "it", let workKey = result.openLibraryWorkKey,
           let description = try? await Self.withTimeout(4, { try await self.openLibraryDescription(workKey: workKey) }) {
            result.synopsis = description
        }
        if result.coverURL == nil {
            result.coverURL = Self.openLibraryCoverURL(isbn: isbn)
        }
        return result
    }

    /// Completa un risultato scelto nella ricerca per titolo (pagine, trama, copertina) senza cambiarne titolo e autori.
    func enrich(_ metadata: BookMetadata) async -> BookMetadata {
        var result = metadata
        if let isbn = metadata.isbn,
           let full = try? await Self.withTimeout(7, { try await self.fetch(isbn: isbn) }) {
            result = result.filling(from: full)
        }
        if result.coverURL == nil || result.synopsis == nil {
            let title = result.title
            let author = result.authors.first
            let language = result.languageCode ?? TextMatching.preferredLanguage
            if let apple = try? await Self.withTimeout(3, { try await self.appleBooksMatch(title: title, author: author, language: language) }) {
                result = result.filling(from: apple)
            }
        }
        if result.coverURL == nil, let isbn = result.isbn {
            result.coverURL = Self.openLibraryCoverURL(isbn: isbn)
        }
        return result
    }

    // MARK: Ricerca per titolo / autore

    /// Ricerca progressiva: ogni catalogo che risponde aggiorna la lista, ordinata per pertinenza e lingua.
    func searchStream(query rawQuery: String) -> AsyncThrowingStream<SearchUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let query = rawQuery.trimmed
                    guard !query.isEmpty else { throw MetadataFetchError.emptyQuery }

                    if ISBN.normalize(query) != nil {
                        let result = try await self.fetch(isbn: query)
                        continuation.yield(SearchUpdate(results: [result], isFinal: true))
                        continuation.finish()
                        return
                    }

                    let cacheKey = "q:\(query.lowercased())" as NSString
                    if let cached = self.cache.object(forKey: cacheKey) {
                        continuation.yield(SearchUpdate(results: cached.results, isFinal: true))
                        continuation.finish()
                        return
                    }

                    let language = TextMatching.queryLanguage(query)
                    let jobs = self.searchJobs(query: query, language: language)
                    var lists: [[BookMetadata]] = []
                    var errors: [Error] = []

                    await withTaskGroup(of: SearchEvent.self) { group in
                        for job in jobs {
                            group.addTask {
                                do {
                                    return .results(try await BookMetadataFetcher.withTimeout(9, job))
                                } catch {
                                    return .failure(error)
                                }
                            }
                        }
                        for await event in group {
                            switch event {
                            case .results(let items):
                                lists.append(items)
                                let ranked = BookMetadataFetcher.rank(lists, query: query, language: language)
                                if !ranked.isEmpty {
                                    continuation.yield(SearchUpdate(results: ranked, isFinal: false))
                                }
                            case .failure(let error):
                                errors.append(error)
                            }
                        }
                    }

                    try Task.checkCancellation()
                    let final = BookMetadataFetcher.rank(lists, query: query, language: language)
                    // Errore solo se nessun catalogo ha risposto; se hanno risposto senza risultati la lista è vuota.
                    if final.isEmpty, lists.isEmpty, !errors.isEmpty {
                        throw BookMetadataFetcher.resolve(errors)
                    }
                    if !final.isEmpty {
                        self.cache.setObject(CachedResults(results: final), forKey: cacheKey)
                    }
                    continuation.yield(SearchUpdate(results: final, isFinal: true))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Versione non progressiva della ricerca.
    func search(query: String) async throws -> [BookMetadata] {
        var latest: [BookMetadata] = []
        for try await update in searchStream(query: query) {
            latest = update.results
        }
        return latest
    }

    private func searchJobs(query: String, language: String) -> [@Sendable () async throws -> [BookMetadata]] {
        var jobs: [@Sendable () async throws -> [BookMetadata]] = [
            { try await self.sbnSearch(text: query) },
            { try await self.appleBooksSearch(term: query, language: language) },
            { try await self.openLibrarySearch(query: query, language: language) }
        ]
        if isGoogleAvailable {
            jobs.append { try await self.googleSearch(query: query, language: language) }
        }
        return jobs
    }

    // MARK: Download copertina

    func downloadCover(from url: URL) async throws -> UIImage {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let image = UIImage(data: data),
              image.size.width > 20, image.size.height > 20
        else { throw MetadataFetchError.notFound }
        return image
    }

    // MARK: Unione e ordinamento

    /// Ordine di affidabilità delle sorgenti per i dati principali (titolo, autori, pagine).
    static func sourceOrder(for language: String?) -> [BookMetadata.Source] {
        language == "it"
            ? [.sbn, .googleBooks, .openLibrary, .appleBooks]
            : [.googleBooks, .openLibrary, .sbn, .appleBooks]
    }

    private static func isbnLanguageGuess(_ isbn: String) -> String? {
        // Gruppi 978-0 e 978-1: area anglofona.
        if isbn.hasPrefix("9780") || isbn.hasPrefix("9781") { return "en" }
        return nil
    }

    /// Chiave che identifica lo stesso libro tra cataloghi diversi (titolo + cognome del primo autore).
    static func bookKey(_ item: BookMetadata) -> String {
        TextMatching.titleKey(item.title) + "|" + TextMatching.surnameKey(item.authors.first)
    }

    static func rank(_ lists: [[BookMetadata]], query: String, language: String) -> [BookMetadata] {
        let order = sourceOrder(for: language)
        let all = lists.flatMap { $0 }.sorted {
            (order.firstIndex(of: $0.source) ?? 9) < (order.firstIndex(of: $1.source) ?? 9)
        }

        // 1. Unione dei duplicati: stesso ISBN, oppure stesso titolo e autore senza ISBN.
        var merged: [BookMetadata] = []
        var indexByISBN: [String: Int] = [:]
        var indexByKey: [String: Int] = [:]
        for item in all {
            let key = bookKey(item)
            if let isbn = item.isbn, let index = indexByISBN[isbn] {
                merged[index] = merged[index].filling(from: item)
                continue
            }
            if let index = indexByKey[key] {
                if item.isbn == nil {
                    merged[index] = merged[index].filling(from: item)
                    continue
                }
                if merged[index].isbn == nil, let isbn = item.isbn {
                    merged[index] = item.filling(from: merged[index])
                    indexByISBN[isbn] = index
                    continue
                }
            }
            merged.append(item)
            let index = merged.count - 1
            if let isbn = item.isbn { indexByISBN[isbn] = index }
            if indexByKey[key] == nil { indexByKey[key] = index }
        }

        // 2. Le edizioni dello stesso libro condividono la copertina e la trama trovate altrove.
        var sharedCover: [String: (cover: URL, thumbnail: URL?)] = [:]
        var sharedSynopsis: [String: String] = [:]
        for item in merged {
            let key = bookKey(item)
            if let cover = item.coverURL, sharedCover[key] == nil {
                sharedCover[key] = (cover, item.thumbnailURL)
            }
            if let synopsis = item.synopsis, sharedSynopsis[key] == nil {
                sharedSynopsis[key] = synopsis
            }
        }
        for index in merged.indices {
            let key = bookKey(merged[index])
            if merged[index].coverURL == nil, let shared = sharedCover[key] {
                merged[index].coverURL = shared.cover
                merged[index].thumbnailURL = shared.thumbnail
            }
            if merged[index].synopsis == nil, let synopsis = sharedSynopsis[key] {
                merged[index].synopsis = synopsis
            }
        }

        // 3. Punteggio: pertinenza, lingua della ricerca, completezza dei dati.
        let scored = merged
            .map { (item: $0, score: score($0, query: query, language: language)) }
            .sorted { $0.score > $1.score }

        // 4. Al massimo tre edizioni per libro, per non riempire la lista di ristampe.
        var perBook: [String: Int] = [:]
        var result: [BookMetadata] = []
        for entry in scored where entry.score > 10 {
            let key = bookKey(entry.item)
            let count = perBook[key, default: 0]
            guard count < 3 else { continue }
            perBook[key] = count + 1
            result.append(entry.item)
            if result.count >= 40 { break }
        }
        return result
    }

    static func score(_ item: BookMetadata, query: String, language: String) -> Double {
        var value = TextMatching.relevance(query: query, title: item.title, authors: item.authors) * 100
        if let code = item.languageCode {
            value += code == language ? 25 : -15
        }
        if item.isbn != nil { value += 8 }
        if item.coverURL != nil { value += 6 }
        if item.pageCount != nil { value += 3 }
        if item.publicationYear != nil { value += 1 }
        return value
    }

    // MARK: Utilità di rete

    func getJSON<T: Decodable>(_ url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        }
        let (data, response) = result

        guard let http = response as? HTTPURLResponse else { throw MetadataFetchError.invalidResponse }
        switch http.statusCode {
        case 200..<300:
            break
        case 404:
            throw MetadataFetchError.notFound
        case 403, 429, 500...599:
            throw MetadataFetchError.serviceUnavailable
        default:
            throw MetadataFetchError.invalidResponse
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw MetadataFetchError.invalidResponse
        }
    }

    static func makeURL(_ base: String, query: [String: String]) throws -> URL {
        guard var components = URLComponents(string: base) else { throw MetadataFetchError.invalidResponse }
        if !query.isEmpty {
            components.queryItems = query
                .sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw MetadataFetchError.invalidResponse }
        return url
    }

    /// Esegue l'operazione con un tempo massimo; allo scadere lancia `MetadataFetchError.timeout`.
    static func withTimeout<T: Sendable>(
        _ seconds: Double,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw MetadataFetchError.timeout
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else { throw MetadataFetchError.timeout }
            return value
        }
    }

    /// Esegue le ricerche per ISBN in parallelo. Si ferma quando tutte hanno risposto, oppure
    /// `grace` secondi dopo il primo risultato, oppure allo scadere di `timeout`.
    private func collect(
        _ jobs: [(BookMetadata.Source, @Sendable () async throws -> BookMetadata)],
        timeout: Double,
        grace: Double
    ) async -> (results: [BookMetadata.Source: BookMetadata], errors: [Error]) {
        await withTaskGroup(of: CollectEvent.self) { group in
            for (source, job) in jobs {
                group.addTask {
                    do {
                        return .success(source, try await BookMetadataFetcher.withTimeout(timeout, job))
                    } catch {
                        return .failure(error)
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout + 0.5))
                return .deadline
            }

            var results: [BookMetadata.Source: BookMetadata] = [:]
            var errors: [Error] = []
            var remaining = jobs.count
            var isGraceRunning = false

            eventLoop: while let event = await group.next() {
                switch event {
                case .success(let source, let metadata):
                    remaining -= 1
                    results[source] = metadata
                    if !isGraceRunning {
                        isGraceRunning = true
                        group.addTask {
                            try? await Task.sleep(for: .seconds(grace))
                            return .deadline
                        }
                    }
                case .failure(let error):
                    remaining -= 1
                    errors.append(error)
                case .deadline:
                    break eventLoop
                }
                if remaining == 0 { break }
            }
            group.cancelAll()
            return (results, errors)
        }
    }

    /// Distingue una vera assenza di connessione da un servizio lento o non disponibile.
    static func resolve(_ failures: [Error]) -> Error {
        if failures.contains(where: { $0 is CancellationError }) {
            return CancellationError()
        }
        let urlErrors = failures.compactMap { $0 as? URLError }
        let offlineCodes: Set<URLError.Code> = [
            .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
            .internationalRoamingOff, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed
        ]
        if !urlErrors.isEmpty, urlErrors.count == failures.count,
           urlErrors.allSatisfy({ offlineCodes.contains($0.code) }) {
            return MetadataFetchError.network
        }
        let fetchErrors = failures.compactMap { $0 as? MetadataFetchError }
        if fetchErrors.contains(.notFound) || failures.isEmpty {
            return MetadataFetchError.notFound
        }
        if fetchErrors.contains(.timeout) || urlErrors.contains(where: { $0.code == .timedOut }) {
            return MetadataFetchError.timeout
        }
        if fetchErrors.contains(.serviceUnavailable) || !urlErrors.isEmpty {
            return MetadataFetchError.serviceUnavailable
        }
        return MetadataFetchError.invalidResponse
    }
}

private enum CollectEvent: Sendable {
    case success(BookMetadata.Source, BookMetadata)
    case failure(Error)
    case deadline
}

private enum SearchEvent: Sendable {
    case results([BookMetadata])
    case failure(Error)
}

/// Contenitore per la cache in memoria dei risultati.
private final class CachedResults {
    let results: [BookMetadata]

    init(results: [BookMetadata]) {
        self.results = results
    }
}
