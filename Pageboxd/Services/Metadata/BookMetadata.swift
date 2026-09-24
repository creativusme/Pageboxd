import Foundation
import NaturalLanguage

// MARK: - ISBN

enum ISBN {
    /// Restituisce l'ISBN-13 normalizzato se l'input è un ISBN-10 o ISBN-13 valido, altrimenti `nil`.
    static func normalize(_ raw: String) -> String? {
        let cleaned = cleanedCharacters(raw)
        if cleaned.count == 13, isValidISBN13(cleaned), cleaned.hasPrefix("978") || cleaned.hasPrefix("979") {
            return cleaned
        }
        if cleaned.count == 10, isValidISBN10(cleaned) {
            return convertToISBN13(cleaned)
        }
        return nil
    }

    /// Mantiene solo cifre e la "X" finale degli ISBN-10.
    static func cleanedCharacters(_ raw: String) -> String {
        raw.uppercased().filter { ("0"..."9").contains($0) || $0 == "X" }
    }

    static func isValidISBN10(_ value: String) -> Bool {
        let characters = Array(value)
        guard characters.count == 10 else { return false }
        var sum = 0
        for (index, character) in characters.enumerated() {
            let digit: Int
            if character == "X" {
                guard index == 9 else { return false }
                digit = 10
            } else if let number = character.wholeNumberValue {
                digit = number
            } else {
                return false
            }
            sum += digit * (10 - index)
        }
        return sum % 11 == 0
    }

    static func isValidISBN13(_ value: String) -> Bool {
        let digits = value.compactMap { $0.wholeNumberValue }
        guard value.count == 13, digits.count == 13 else { return false }
        return weightedSum(digits) % 10 == 0
    }

    static func convertToISBN13(_ isbn10: String) -> String {
        let core = "978" + String(isbn10.prefix(9))
        let digits = core.compactMap { $0.wholeNumberValue }
        let checkDigit = (10 - weightedSum(digits) % 10) % 10
        return core + String(checkDigit)
    }

    /// ISBN-10 equivalente (solo per i codici 978). I cataloghi più vecchi conoscono solo questa forma.
    static func toISBN10(_ isbn13: String) -> String? {
        guard isbn13.count == 13, isbn13.hasPrefix("978") else { return nil }
        let core = String(isbn13.dropFirst(3).prefix(9))
        let digits = core.compactMap { $0.wholeNumberValue }
        guard digits.count == 9 else { return nil }
        let sum = digits.enumerated().reduce(0) { $0 + $1.element * (10 - $1.offset) }
        let check = (11 - sum % 11) % 11
        return core + (check == 10 ? "X" : String(check))
    }

    /// ISBN-13 seguito dall'eventuale ISBN-10.
    static func variants(of isbn13: String) -> [String] {
        [isbn13] + (toISBN10(isbn13).map { [$0] } ?? [])
    }

    /// Libri pubblicati in Italia (gruppi 978-88 e 979-12).
    static func isItalian(_ isbn13: String) -> Bool {
        isbn13.hasPrefix("97888") || isbn13.hasPrefix("97912")
    }

    private static func weightedSum(_ digits: [Int]) -> Int {
        digits.enumerated().reduce(0) { partial, element in
            partial + element.element * (element.offset % 2 == 0 ? 1 : 3)
        }
    }
}

// MARK: - Modello dei metadati

struct BookMetadata: Identifiable, Hashable, Sendable {
    enum Source: String, Sendable, CaseIterable {
        case sbn = "Biblioteche italiane (SBN)"
        case openLibrary = "Open Library"
        case appleBooks = "Apple Books"
        case googleBooks = "Google Books"

        var shortName: String {
            switch self {
            case .sbn: return "SBN"
            case .openLibrary: return "Open Library"
            case .appleBooks: return "Apple Books"
            case .googleBooks: return "Google"
            }
        }
    }

    var id: String
    var isbn: String?
    var title: String
    var authors: [String]
    var publicationYear: Int?
    var pageCount: Int?
    var synopsis: String?
    var coverURL: URL?
    var languageCode: String?
    var source: Source
    var publisher: String? = nil
    /// Anteprima leggera per le liste, quando la sorgente ne fornisce una.
    var thumbnailURL: URL? = nil
    /// Chiave dell'opera su Open Library (es. "/works/OL123W"), usata per recuperare la trama.
    var openLibraryWorkKey: String? = nil

    var authorLine: String { authors.joined(separator: ", ") }

    /// Anteprima leggera per le liste di risultati (le copertine grandi rallentano lo scorrimento).
    var listThumbnailURL: URL? {
        if let thumbnailURL { return thumbnailURL }
        guard let coverURL else { return nil }
        let string = coverURL.absoluteString
        guard string.contains("covers.openlibrary.org") else { return coverURL }
        return URL(string: string.replacingOccurrences(of: "-L.jpg", with: "-M.jpg"))
    }

    var isMissingDetails: Bool {
        authors.isEmpty || publicationYear == nil || pageCount == nil || synopsis == nil || coverURL == nil
    }

    /// Completa i campi mancanti con i dati di un'altra sorgente, senza sovrascrivere quelli presenti.
    func filling(from other: BookMetadata) -> BookMetadata {
        var result = self
        if result.authors.isEmpty { result.authors = other.authors }
        if result.publicationYear == nil { result.publicationYear = other.publicationYear }
        if result.pageCount == nil { result.pageCount = other.pageCount }
        if result.synopsis == nil { result.synopsis = other.synopsis }
        if result.coverURL == nil { result.coverURL = other.coverURL }
        if result.thumbnailURL == nil { result.thumbnailURL = other.thumbnailURL }
        if result.languageCode == nil { result.languageCode = other.languageCode }
        if result.isbn == nil { result.isbn = other.isbn }
        if result.publisher == nil { result.publisher = other.publisher }
        if result.openLibraryWorkKey == nil { result.openLibraryWorkKey = other.openLibraryWorkKey }
        return result
    }
}

enum MetadataFetchError: LocalizedError, Equatable {
    case invalidISBN
    case emptyQuery
    case notFound
    case network
    case timeout
    case serviceUnavailable
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidISBN: return "Il codice scansionato non è un ISBN valido."
        case .emptyQuery: return "Inserisci un titolo, un autore o un ISBN."
        case .notFound: return "Nessun libro trovato nei cataloghi online."
        case .network: return "Connessione a Internet non disponibile. Puoi comunque inserire il libro manualmente."
        case .timeout: return "I cataloghi online non rispondono in tempo. Riprova tra poco."
        case .serviceUnavailable: return "I cataloghi online non sono disponibili al momento. Riprova tra poco."
        case .invalidResponse: return "Il servizio di catalogo ha restituito una risposta non valida."
        }
    }
}

// MARK: - Parsing

enum MetadataParsing {
    static func year(from value: String?) -> Int? {
        guard let value, let range = value.range(of: #"\d{4}"#, options: .regularExpression) else { return nil }
        return Int(value[range])
    }

    /// Ultimo anno a 4 cifre presente nel testo (es. "Milano : Bompiani, 1980, ristampa 2003" → 2003).
    static func lastYear(in value: String?) -> Int? {
        let maxYear = Calendar.current.component(.year, from: Date()) + 1
        return allMatches(of: #"\b(1[5-9]\d{2}|20\d{2})\b"#, in: value)
            .compactMap { Int($0) }
            .filter { $0 <= maxYear }
            .last
    }

    /// Numero di pagine da una descrizione fisica ("XII, 379 p. ; 21 cm" → 379).
    static func pages(fromPhysicalDescription value: String?) -> Int? {
        allMatches(of: #"(\d{1,5})\s*(?:p\.|pp\.|pagine|pages)"#, in: value, group: 1)
            .compactMap { Int($0) }
            .filter { $0 > 0 && $0 < 20_000 }
            .max()
    }

    static func allMatches(of pattern: String, in value: String?, group: Int = 0) -> [String] {
        guard let value, !value.isEmpty,
              let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return [] }
        let nsValue = value as NSString
        return regex.matches(in: value, range: NSRange(location: 0, length: nsValue.length)).compactMap { match in
            guard group < match.numberOfRanges else { return nil }
            let range = match.range(at: group)
            guard range.location != NSNotFound else { return nil }
            return nsValue.substring(with: range)
        }
    }

    static func cleanDescription(_ value: String?) -> String? {
        guard var text = value else { return nil }
        text = text.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"</p>"#, with: "\n\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        let entities = [
            "&amp;": "&", "&quot;": "\"", "&#39;": "'", "&apos;": "'",
            "&lt;": "<", "&gt;": ">", "&nbsp;": " "
        ]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return text.nilIfBlank
    }

    static func secureURL(_ value: String?) -> URL? {
        guard var string = value?.trimmed, !string.isEmpty else { return nil }
        if string.hasPrefix("http://") {
            string = "https://" + string.dropFirst("http://".count)
        }
        string = string.replacingOccurrences(of: "&edge=curl", with: "")
        return URL(string: string)
    }

    /// "Martel, Yann <1963- >" → "Yann Martel".
    static func personName(fromCatalogForm value: String) -> String {
        var name = value.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
        name = name.replacingOccurrences(of: #"[\[\]]"#, with: "", options: .regularExpression).trimmed
        let parts = name.components(separatedBy: ", ")
        guard parts.count == 2, !parts[1].isEmpty else { return name }
        return "\(parts[1].trimmed) \(parts[0].trimmed)"
    }

    /// Prima lettera maiuscola (i cataloghi a volte scrivono "il nome della rosa").
    static func capitalizedFirstLetter(_ value: String) -> String {
        guard let first = value.first, first.isLowercase else { return value }
        return first.uppercased() + value.dropFirst()
    }

    static func collapsedWhitespace(_ value: String) -> String {
        value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmed
    }
}

// MARK: - Confronto testi e lingua

enum TextMatching {
    /// Minuscolo e senza accenti.
    static func folded(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .pageboxd)
    }

    static func tokens(_ value: String) -> [String] {
        folded(value)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Chiave normalizzata di un titolo, per riconoscere lo stesso libro da sorgenti diverse.
    static func titleKey(_ title: String) -> String {
        tokens(title).joined(separator: " ")
    }

    /// Chiave di un autore indipendente dall'ordine ("Martel, Yann" = "Yann Martel").
    static func authorKey(_ name: String) -> String {
        tokens(name).sorted().joined(separator: " ")
    }

    static func surnameKey(_ name: String?) -> String {
        guard let name else { return "" }
        let normalized = name.contains(", ") ? MetadataParsing.personName(fromCatalogForm: name) : name
        return tokens(normalized).last ?? ""
    }

    /// Pertinenza 0...1 di un risultato rispetto alla ricerca (titolo e autori).
    static func relevance(query: String, title: String, authors: [String]) -> Double {
        let queryTokens = Set(tokens(query).filter { $0.count > 1 || $0.allSatisfy(\.isNumber) })
        guard !queryTokens.isEmpty else { return 0 }
        let titleTokens = Set(tokens(title))
        let authorTokens = Set(authors.flatMap { tokens($0) })

        let coveredByTitle = queryTokens.intersection(titleTokens).count
        let covered = queryTokens.intersection(titleTokens.union(authorTokens)).count
        let coverage = Double(covered) / Double(queryTokens.count)
        let titlePrecision = titleTokens.isEmpty ? 0 : Double(coveredByTitle) / Double(titleTokens.count)

        var score = coverage * 0.7 + titlePrecision * 0.3
        if titleKey(title) == titleKey(query) { score += 0.3 }
        return min(score, 1.3)
    }

    /// Lingua della ricerca ("vita di pi" → it, "life of pi" → en). Con testi brevi o ambigui
    /// si usa la lingua preferita del dispositivo.
    static func queryLanguage(_ query: String) -> String {
        detectLanguage(of: query, minimumConfidence: tokens(query).count <= 2 ? 0.9 : 0.55) ?? preferredLanguage
    }

    static func detectLanguage(of text: String, minimumConfidence: Double = 0.6) -> String? {
        guard !text.trimmed.isEmpty else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.italian, .english, .french, .spanish, .german, .portuguese]
        recognizer.processString(text)
        guard let best = recognizer.languageHypotheses(withMaximum: 3).max(by: { $0.value < $1.value }),
              best.value >= minimumConfidence
        else { return nil }
        return best.key.rawValue
    }

    static var preferredLanguage: String {
        let code = Locale.preferredLanguages.first.map { String($0.prefix(2)).lowercased() } ?? "it"
        return code.isEmpty ? "it" : code
    }
}
