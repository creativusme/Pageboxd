import Foundation

/// Esporta la libreria in CSV (RFC 4180, UTF-8 con BOM per la compatibilità con Excel e Numbers).
enum CSVExporter {
    /// Istantanea dei dati di un libro, indipendente da SwiftData e quindi elaborabile in background.
    struct Row: Sendable {
        let title: String
        let author: String
        let isbn: String
        let year: String
        let pages: String
        let status: String
        let rating: String
        let liked: String
        let language: String
        let readDates: String
        let timesRead: String
        let dateAdded: String
        let review: String

        init(book: BookItem) {
            title = book.title
            author = book.author
            isbn = book.isbn ?? ""
            year = book.publicationYear.map { String($0) } ?? ""
            pages = book.pageCount.map { String($0) } ?? ""
            status = book.status.displayName
            rating = book.isRated ? String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), book.rating) : ""
            liked = book.liked ? "Sì" : "No"
            language = book.languageDisplayName
            readDates = book.readDates.sorted().map { CSVExporter.dayFormatter.string(from: $0) }.joined(separator: "; ")
            timesRead = book.status == .read ? String(book.timesRead) : ""
            dateAdded = CSVExporter.dayFormatter.string(from: book.dateAdded)
            review = book.review
        }

        var fields: [String] {
            [title, author, isbn, year, pages, status, rating, liked, language, readDates, timesRead, dateAdded, review]
        }
    }

    static let header = [
        "Titolo", "Autore", "ISBN", "Anno", "Pagine", "Stato", "Valutazione", "Liked",
        "Lingua", "Date Lettura", "Volte Letto", "Data Aggiunta", "Recensione"
    ]

    fileprivate static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func makeCSV(rows: [Row]) -> String {
        var lines = [header.map(escape).joined(separator: ",")]
        lines.append(contentsOf: rows.map { $0.fields.map(escape).joined(separator: ",") })
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// Scrive il CSV nella cartella temporanea e restituisce l'URL da condividere.
    static func writeCSV(rows: [Row]) async throws -> URL {
        let csv = makeCSV(rows: rows)
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data(csv.utf8))

        let fileName = "Pageboxd-Export-\(dayFormatter.string(from: Date())).csv"
        let url = FileManager.default.temporaryDirectory.appending(path: fileName, directoryHint: .notDirectory)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return url
    }

    /// Racchiude tra virgolette i campi con separatori e neutralizza le formule nei fogli di calcolo.
    static func escape(_ field: String) -> String {
        var value = field
        if let first = value.first, "=+-@\t\r".contains(first) {
            value = "'" + value
        }
        let needsQuoting = value.contains { $0.isNewline || $0 == "," || $0 == "\"" || $0 == ";" }
        guard needsQuoting else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
