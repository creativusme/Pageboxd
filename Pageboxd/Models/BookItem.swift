import Foundation
import OSLog
import SwiftData

// MARK: - BookItem

@Model
final class BookItem {
    @Attribute(.unique) var id: UUID = UUID()
    var isbn: String?
    var title: String = ""
    /// Autori uniti in una riga ("A, B"): usata per liste, ricerca e ordinamento.
    var author: String = ""
    /// Elenco degli autori. Vuoto nei libri creati prima dell'introduzione degli autori multipli.
    var authorNames: [String] = []
    var publicationYear: Int?
    var pageCount: Int?
    var synopsis: String?
    /// Valore grezzo di `ReadingLanguage` (salvato come stringa per poterlo usare nei `#Predicate`).
    var languageRaw: String = "it"
    /// Codice ISO della lingua quando `language == .other` (es. "fr", "es").
    var otherLanguageCode: String?
    /// Valore grezzo di `ReadingStatus` (salvato come stringa per poterlo usare nei `#Predicate`).
    var statusRaw: String = "watchlist"
    /// 0 = non valutato, altrimenti da 0.5 a 5.0 con passo 0.5.
    var rating: Double = 0
    var liked: Bool = false
    var review: String = ""
    var dateAdded: Date = Date()
    var readDates: [Date] = []
    /// Numero di riletture (volte lette - 1).
    var rereadCount: Int = 0
    /// Foto della propria edizione, percorso relativo alla Documents directory (es. "covers/UUID.jpg").
    var photoPath: String?
    /// Copertina scaricata dal catalogo online, salvata localmente per l'uso offline.
    var remoteCoverPath: String?

    @Relationship(deleteRule: .cascade, inverse: \ReadingLog.book)
    var logs: [ReadingLog] = []

    init(
        id: UUID = UUID(),
        isbn: String? = nil,
        title: String,
        author: String,
        publicationYear: Int? = nil,
        pageCount: Int? = nil,
        synopsis: String? = nil,
        language: ReadingLanguage = .italian,
        otherLanguageCode: String? = nil,
        status: ReadingStatus = .watchlist,
        rating: Double = 0,
        liked: Bool = false,
        review: String = "",
        dateAdded: Date = Date(),
        readDates: [Date] = [],
        rereadCount: Int = 0,
        photoPath: String? = nil,
        remoteCoverPath: String? = nil
    ) {
        self.id = id
        self.isbn = isbn
        self.title = title
        self.author = author
        self.publicationYear = publicationYear
        self.pageCount = pageCount
        self.synopsis = synopsis
        self.languageRaw = language.rawValue
        self.otherLanguageCode = language == .other ? otherLanguageCode : nil
        self.statusRaw = status.rawValue
        self.rating = BookItem.clampedRating(rating)
        self.liked = liked
        self.review = review
        self.dateAdded = dateAdded
        self.readDates = readDates
        self.rereadCount = max(0, rereadCount)
        self.photoPath = photoPath
        self.remoteCoverPath = remoteCoverPath
    }

    // MARK: Proprietà calcolate

    var language: ReadingLanguage {
        get { ReadingLanguage(rawValue: languageRaw) ?? .other }
        set { languageRaw = newValue.rawValue }
    }

    /// Nome leggibile della lingua, con la lingua specifica quando è "Altro".
    var languageDisplayName: String {
        guard language == .other else { return language.displayName }
        return LanguageCatalog.name(for: otherLanguageCode) ?? language.displayName
    }

    var languageShortCode: String {
        guard language == .other, let code = otherLanguageCode else { return language.shortCode }
        return code.uppercased()
    }

    /// Autori del libro (con fallback sul campo testuale per i libri meno recenti).
    var authorList: [String] {
        let names = authorNames.compactMap { $0.nilIfBlank }
        if !names.isEmpty { return names }
        return author.nilIfBlank.map { [$0] } ?? []
    }

    /// Imposta gli autori aggiornando anche la riga testuale.
    func setAuthors(_ names: [String]) {
        let cleaned = names.compactMap { $0.nilIfBlank }
        authorNames = cleaned
        author = cleaned.isEmpty ? "Autore sconosciuto" : cleaned.joined(separator: ", ")
    }

    /// Divide una riga di autori salvata prima degli autori multipli ("Douglas Preston, Lincoln Child").
    /// Non divide le forme catalografiche come "Tolkien, J.R.R.", dove una parte è un solo nome.
    static func splitLegacyAuthors(_ line: String) -> [String] {
        let parts = line.components(separatedBy: ", ").map { $0.trimmed }.filter { !$0.isEmpty }
        guard parts.count > 1, parts.allSatisfy({ $0.split(separator: " ").count >= 2 }) else {
            return line.nilIfBlank.map { [$0] } ?? []
        }
        return parts
    }

    var status: ReadingStatus {
        get { ReadingStatus(rawValue: statusRaw) ?? .watchlist }
        set { statusRaw = newValue.rawValue }
    }

    /// Volte in cui il libro è stato letto (prima lettura + riletture).
    var timesRead: Int {
        get { rereadCount + 1 }
        set { rereadCount = max(0, newValue - 1) }
    }

    var sortedReadDates: [Date] { readDates.sorted(by: >) }
    var lastReadDate: Date? { readDates.max() }
    var firstReadDate: Date? { readDates.min() }

    /// La foto dell'edizione personale ha sempre la priorità sulla copertina del catalogo.
    var coverPath: String? { photoPath ?? remoteCoverPath }
    var hasPersonalPhoto: Bool { photoPath != nil }
    var isRated: Bool { rating > 0 }

    static func clampedRating(_ value: Double) -> Double {
        guard value > 0 else { return 0 }
        let stepped = (value * 2).rounded() / 2
        return min(5, max(0.5, stepped))
    }

    // MARK: Diario

    /// Allinea le voci del diario (`ReadingLog`) alle date di lettura salvate in `readDates`.
    /// Le voci esistenti nello stesso giorno vengono mantenute, le altre create o eliminate.
    func syncReadingLogs(in context: ModelContext) {
        let calendar = Calendar.current
        var pendingDates = readDates
        var keptLogs: [ReadingLog] = []

        for log in logs {
            if let index = pendingDates.firstIndex(where: { calendar.isDate($0, inSameDayAs: log.date) }) {
                log.date = pendingDates.remove(at: index)
                keptLogs.append(log)
            } else {
                context.delete(log)
            }
        }

        for date in pendingDates {
            let log = ReadingLog(date: date)
            context.insert(log)
            keptLogs.append(log)
        }

        logs = keptLogs
    }
}

// MARK: - Eliminazione con pulizia dei file

extension BookItem {
    /// Elimina il libro dal database e, solo a salvataggio riuscito, rimuove le immagini dal disco.
    func deleteWithAssets(from context: ModelContext) {
        let paths = [photoPath, remoteCoverPath].compactMap { $0 }
        context.delete(self)
        do {
            try context.save()
            paths.forEach { ImageStorageManager.shared.deleteImage(relativePath: $0) }
        } catch {
            context.rollback()
            Logger.pageboxd.error("Eliminazione libro fallita: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Rimuove una singola lettura dal diario, aggiornando date e conteggio riletture.
    func removeReading(on date: Date, in context: ModelContext) {
        let calendar = Calendar.current
        if let index = readDates.firstIndex(where: { calendar.isDate($0, inSameDayAs: date) }) {
            readDates.remove(at: index)
        }
        if timesRead > max(1, readDates.count) {
            timesRead -= 1
        }
        syncReadingLogs(in: context)
        context.saveLogging()
    }
}

// MARK: - Migrazione autori multipli

enum AuthorMigration {
    /// Popola `authorNames` per i libri salvati prima dell'introduzione degli autori multipli.
    static func runIfNeeded(in context: ModelContext) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: AppStorageKeys.authorNamesMigrated) else { return }
        guard let books = try? context.fetch(FetchDescriptor<BookItem>()) else { return }
        for book in books where book.authorNames.isEmpty && !book.author.trimmed.isEmpty {
            book.authorNames = BookItem.splitLegacyAuthors(book.author)
        }
        do {
            if context.hasChanges { try context.save() }
            defaults.set(true, forKey: AppStorageKeys.authorNamesMigrated)
        } catch {
            context.rollback()
            Logger.pageboxd.error("Migrazione autori fallita: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - ReadingLog

/// Una singola voce del diario: ogni lettura (o rilettura) di un libro.
@Model
final class ReadingLog {
    @Attribute(.unique) var id: UUID = UUID()
    var date: Date = Date()
    var book: BookItem?

    init(id: UUID = UUID(), date: Date) {
        self.id = id
        self.date = date
    }

    /// `true` se questa lettura è successiva alla prima lettura del libro.
    var isReread: Bool {
        guard let first = book?.firstReadDate else { return false }
        return date > first && !Calendar.current.isDate(date, inSameDayAs: first)
    }
}
