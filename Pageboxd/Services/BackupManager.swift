import Foundation
import OSLog
import SwiftData
import UIKit

// MARK: - Formato del backup

/// Copia completa di un libro, indipendente da SwiftData.
struct BackupBook: Codable, Sendable {
    var id: UUID
    var isbn: String?
    var title: String
    var author: String
    /// Assente nei backup creati prima degli autori multipli.
    var authors: [String]?
    var publicationYear: Int?
    var pageCount: Int?
    var synopsis: String?
    var language: String
    var otherLanguageCode: String?
    var status: String
    var rating: Double
    var liked: Bool
    var review: String
    var dateAdded: Date
    var readDates: [Date]
    var rereadCount: Int
    var photoPath: String?
    var remoteCoverPath: String?

    init(book: BookItem) {
        id = book.id
        isbn = book.isbn
        title = book.title
        author = book.author
        authors = book.authorList
        publicationYear = book.publicationYear
        pageCount = book.pageCount
        synopsis = book.synopsis
        language = book.languageRaw
        otherLanguageCode = book.otherLanguageCode
        status = book.statusRaw
        rating = book.rating
        liked = book.liked
        review = book.review
        dateAdded = book.dateAdded
        readDates = book.readDates
        rereadCount = book.rereadCount
        photoPath = book.photoPath
        remoteCoverPath = book.remoteCoverPath
    }

    var imagePaths: [String] { [photoPath, remoteCoverPath].compactMap { $0 } }
}

/// Struttura della cartella di backup:
/// ```
/// Pageboxd Backup/
/// ├── library.json            tutti i libri
/// ├── library.previous.json   versione precedente (rete di sicurezza)
/// └── covers/                 foto delle edizioni e copertine
/// ```
struct BackupArchive: Codable, Sendable {
    var formatVersion: Int
    var exportedAt: Date
    var books: [BackupBook]
}

struct RestoreResult: Sendable {
    var imported = 0
    var skipped = 0
}

enum BackupError: LocalizedError {
    case folderNotConfigured
    case accessDenied
    case unreadableBackup
    case unsupportedVersion

    var errorDescription: String? {
        switch self {
        case .folderNotConfigured:
            return "Nessuna cartella di backup configurata."
        case .accessDenied:
            return "Non è più possibile accedere alla cartella di backup. Selezionala di nuovo nelle Impostazioni."
        case .unreadableBackup:
            return "Il file di backup è danneggiato o non leggibile."
        case .unsupportedVersion:
            return "Questo backup è stato creato da una versione più recente di Pageboxd."
        }
    }
}

// MARK: - BackupManager

/// Salva una copia completa della libreria in una cartella scelta dall'utente nell'app File
/// (consigliato: iCloud Drive). La cartella si trova fuori dalla sandbox dell'app, quindi
/// sopravvive anche alla cancellazione e reinstallazione dell'app (sideload ogni 7 giorni).
final class BackupManager: @unchecked Sendable {
    static let shared = BackupManager()

    static let formatVersion = 1
    static let archiveFileName = "library.json"
    static let previousArchiveFileName = "library.previous.json"
    static let backupFolderName = "Pageboxd Backup"

    private enum Keys {
        static let bookmark = "backup.folderBookmark"
        static let usesSubfolder = "backup.usesSubfolder"
        static let lastBackup = "backup.lastDate"
        static let lastError = "backup.lastError"
    }

    private let fileManager = FileManager.default
    private let defaults = UserDefaults.standard

    private init() {}

    // MARK: Stato

    var isFolderConfigured: Bool { defaults.data(forKey: Keys.bookmark) != nil }

    var lastBackupDate: Date? {
        let timestamp = defaults.double(forKey: Keys.lastBackup)
        return timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
    }

    var lastErrorMessage: String? { defaults.string(forKey: Keys.lastError) }

    var folderDisplayName: String? {
        guard let folder = try? resolveBookmarkedFolder() else { return nil }
        let usesSubfolder = defaults.bool(forKey: Keys.usesSubfolder)
        return usesSubfolder ? "\(folder.lastPathComponent)/\(Self.backupFolderName)" : folder.lastPathComponent
    }

    func disconnectFolder() {
        defaults.removeObject(forKey: Keys.bookmark)
        defaults.removeObject(forKey: Keys.usesSubfolder)
        defaults.removeObject(forKey: Keys.lastError)
    }

    // MARK: Collegamento cartella

    /// Collega la cartella scelta dall'utente. Se contiene già un backup Pageboxd lo restituisce,
    /// così l'app può proporre il ripristino (tipico dopo una reinstallazione).
    func connectFolder(_ pickedURL: URL) async throws -> BackupArchive? {
        let isAccessing = pickedURL.startAccessingSecurityScopedResource()
        defer { if isAccessing { pickedURL.stopAccessingSecurityScopedResource() } }

        let bookmark = try pickedURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)

        let usesSubfolder: Bool
        if archiveExists(in: pickedURL) || pickedURL.lastPathComponent == Self.backupFolderName {
            usesSubfolder = false
        } else {
            usesSubfolder = true
        }

        defaults.set(bookmark, forKey: Keys.bookmark)
        defaults.set(usesSubfolder, forKey: Keys.usesSubfolder)
        defaults.removeObject(forKey: Keys.lastError)

        let root = usesSubfolder ? pickedURL.appending(path: Self.backupFolderName, directoryHint: .isDirectory) : pickedURL
        guard archiveExists(in: root) else { return nil }
        return try readArchive(in: root)
    }

    private func resolveBookmarkedFolder() throws -> URL {
        guard let bookmark = defaults.data(forKey: Keys.bookmark) else { throw BackupError.folderNotConfigured }
        var isStale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
        if isStale {
            let isAccessing = url.startAccessingSecurityScopedResource()
            defer { if isAccessing { url.stopAccessingSecurityScopedResource() } }
            if let refreshed = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                defaults.set(refreshed, forKey: Keys.bookmark)
            }
        }
        return url
    }

    /// Esegue `body` con accesso alla cartella di backup (radice che contiene `library.json`).
    private func withBackupRoot<T>(_ body: (URL) throws -> T) throws -> T {
        let folder: URL
        do {
            folder = try resolveBookmarkedFolder()
        } catch BackupError.folderNotConfigured {
            throw BackupError.folderNotConfigured
        } catch {
            throw BackupError.accessDenied
        }
        guard folder.startAccessingSecurityScopedResource() else { throw BackupError.accessDenied }
        defer { folder.stopAccessingSecurityScopedResource() }

        let root = defaults.bool(forKey: Keys.usesSubfolder)
            ? folder.appending(path: Self.backupFolderName, directoryHint: .isDirectory)
            : folder
        return try body(root)
    }

    // MARK: Backup

    @MainActor
    static func makeArchive(from context: ModelContext) throws -> BackupArchive {
        let descriptor = FetchDescriptor<BookItem>(sortBy: [SortDescriptor(\.dateAdded)])
        let books = try context.fetch(descriptor)
        return BackupArchive(formatVersion: formatVersion, exportedAt: Date(), books: books.map(BackupBook.init(book:)))
    }

    /// Scrive sempre la copia locale (Documenti, visibile nell'app File) e, se configurata,
    /// quella nella cartella esterna.
    func performBackup(_ archive: BackupArchive) async throws {
        // Non sovrascrivere mai un backup esistente con una libreria vuota
        // (es. subito dopo una reinstallazione, prima del ripristino).
        guard !archive.books.isEmpty else { return }

        let data = try encode(archive)
        try writeArchiveData(data, in: URL.documentsDirectory)

        guard isFolderConfigured else { return }
        do {
            try withBackupRoot { root in
                try coordinatedWrite(at: root) { url in
                    try self.syncBackupFolder(at: url, archiveData: data, imagePaths: archive.books.flatMap(\.imagePaths))
                }
            }
            defaults.set(Date().timeIntervalSince1970, forKey: Keys.lastBackup)
            defaults.removeObject(forKey: Keys.lastError)
        } catch {
            defaults.set(error.localizedDescription, forKey: Keys.lastError)
            throw error
        }
    }

    private func syncBackupFolder(at root: URL, archiveData: Data, imagePaths: [String]) throws {
        let coversURL = root.appending(path: ImageStorageManager.coversDirectoryName, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: coversURL, withIntermediateDirectories: true)

        // Le foto hanno nomi univoci e non vengono mai modificate: si copiano solo quelle nuove.
        // Nessuna foto viene cancellata dal backup, per non perdere dati in caso di errore.
        let existing = Set((try? fileManager.contentsOfDirectory(atPath: coversURL.path(percentEncoded: false))) ?? [])
        for relativePath in Set(imagePaths) {
            let fileName = (relativePath as NSString).lastPathComponent
            guard !existing.contains(fileName) else { continue }
            let source = ImageStorageManager.shared.absoluteURL(for: relativePath)
            guard fileManager.fileExists(atPath: source.path(percentEncoded: false)) else { continue }
            try fileManager.copyItem(at: source, to: coversURL.appending(path: fileName, directoryHint: .notDirectory))
        }

        try writeArchiveData(archiveData, in: root)
    }

    /// Scrive `library.json`, conservando la versione precedente come `library.previous.json`.
    private func writeArchiveData(_ data: Data, in root: URL) throws {
        let archiveURL = root.appending(path: Self.archiveFileName, directoryHint: .notDirectory)
        let previousURL = root.appending(path: Self.previousArchiveFileName, directoryHint: .notDirectory)

        if fileManager.fileExists(atPath: archiveURL.path(percentEncoded: false)) {
            if let current = try? Data(contentsOf: archiveURL), current != data {
                try? current.write(to: previousURL, options: .atomic)
            }
        }
        try data.write(to: archiveURL, options: [.atomic])
    }

    // MARK: Ripristino

    /// Legge il backup dalla cartella collegata.
    func loadConfiguredArchive() async throws -> BackupArchive {
        try withBackupRoot { (root: URL) -> BackupArchive in
            guard archiveExists(in: root) else { throw BackupError.unreadableBackup }
            return try readArchive(in: root)
        }
    }

    /// Copia nella sandbox le foto del backup che mancano sul dispositivo.
    func restoreImages(for archive: BackupArchive) async throws {
        try withBackupRoot { (root: URL) -> Void in
            let coversURL = root.appending(path: ImageStorageManager.coversDirectoryName, directoryHint: .isDirectory)
            let localCovers = ImageStorageManager.shared.coversDirectory
            try fileManager.createDirectory(at: localCovers, withIntermediateDirectories: true)

            for relativePath in Set(archive.books.flatMap(\.imagePaths)) {
                let fileName = (relativePath as NSString).lastPathComponent
                let destination = localCovers.appending(path: fileName, directoryHint: .notDirectory)
                guard !fileManager.fileExists(atPath: destination.path(percentEncoded: false)) else { continue }
                let source = coversURL.appending(path: fileName, directoryHint: .notDirectory)
                do {
                    try coordinatedRead(at: source) { url in
                        try self.fileManager.copyItem(at: url, to: destination)
                    }
                } catch {
                    Logger.pageboxd.error("Foto non ripristinata \(fileName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// Inserisce nel database i libri del backup che non sono già presenti (confronto per ID).
    @MainActor
    static func importArchive(_ archive: BackupArchive, into context: ModelContext) throws -> RestoreResult {
        let existingIDs = Set(try context.fetch(FetchDescriptor<BookItem>()).map(\.id))
        let storage = ImageStorageManager.shared
        var result = RestoreResult()

        func localPath(_ path: String?) -> String? {
            guard let path else { return nil }
            let exists = FileManager.default.fileExists(atPath: storage.absoluteURL(for: path).path(percentEncoded: false))
            return exists ? path : nil
        }

        for item in archive.books {
            guard !existingIDs.contains(item.id) else {
                result.skipped += 1
                continue
            }
            let book = BookItem(
                id: item.id,
                isbn: item.isbn,
                title: item.title,
                author: item.author,
                publicationYear: item.publicationYear,
                pageCount: item.pageCount,
                synopsis: item.synopsis,
                language: ReadingLanguage(rawValue: item.language) ?? .other,
                otherLanguageCode: item.otherLanguageCode,
                status: ReadingStatus(rawValue: item.status) ?? .watchlist,
                rating: item.rating,
                liked: item.liked,
                review: item.review,
                dateAdded: item.dateAdded,
                readDates: item.readDates,
                rereadCount: item.rereadCount,
                photoPath: localPath(item.photoPath),
                remoteCoverPath: localPath(item.remoteCoverPath)
            )
            book.setAuthors(item.authors ?? BookItem.splitLegacyAuthors(item.author))
            context.insert(book)
            book.syncReadingLogs(in: context)
            result.imported += 1
        }

        do {
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
        return result
    }

    // MARK: File

    private func encode(_ archive: BackupArchive) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(archive)
    }

    private func decode(_ data: Data) throws -> BackupArchive {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let archive = try? decoder.decode(BackupArchive.self, from: data) else {
            throw BackupError.unreadableBackup
        }
        guard archive.formatVersion <= Self.formatVersion else { throw BackupError.unsupportedVersion }
        return archive
    }

    /// Considera anche i file di iCloud Drive non ancora scaricati (segnaposto `.nome.icloud`).
    private func archiveExists(in root: URL) -> Bool {
        let archive = root.appending(path: Self.archiveFileName, directoryHint: .notDirectory)
        let placeholder = root.appending(path: ".\(Self.archiveFileName).icloud", directoryHint: .notDirectory)
        return fileManager.fileExists(atPath: archive.path(percentEncoded: false))
            || fileManager.fileExists(atPath: placeholder.path(percentEncoded: false))
    }

    private func readArchive(in root: URL) throws -> BackupArchive {
        let archiveURL = root.appending(path: Self.archiveFileName, directoryHint: .notDirectory)
        var data = Data()
        try coordinatedRead(at: archiveURL) { url in
            data = try Data(contentsOf: url)
        }
        return try decode(data)
    }

    /// La lettura coordinata scarica automaticamente da iCloud i file non ancora presenti.
    private func coordinatedRead(at url: URL, _ body: (URL) throws -> Void) throws {
        var coordinationError: NSError?
        var bodyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            do { try body(readURL) } catch { bodyError = error }
        }
        if let coordinationError { throw coordinationError }
        if let bodyError { throw bodyError }
    }

    private func coordinatedWrite(at url: URL, _ body: (URL) throws -> Void) throws {
        var coordinationError: NSError?
        var bodyError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordinationError) { writeURL in
            do { try body(writeURL) } catch { bodyError = error }
        }
        if let coordinationError { throw coordinationError }
        if let bodyError { throw bodyError }
    }
}

// MARK: - Backup automatico

/// Esegue il backup poco dopo ogni salvataggio e quando l'app va in background.
@MainActor
enum AutoBackup {
    private static var pendingTask: Task<Void, Never>?

    static func schedule(context: ModelContext, after delay: Duration = .seconds(4)) {
        pendingTask?.cancel()
        pendingTask = Task { @MainActor in
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            await run(context: context)
        }
    }

    static func run(context: ModelContext) async {
        let archive: BackupArchive
        do {
            archive = try BackupManager.makeArchive(from: context)
        } catch {
            Logger.pageboxd.error("Snapshot backup fallito: \(error.localizedDescription, privacy: .public)")
            return
        }

        // Chiede a iOS qualche secondo extra se l'app sta andando in background.
        let taskID = UIApplication.shared.beginBackgroundTask(withName: "PageboxdBackup")
        defer {
            if taskID != .invalid { UIApplication.shared.endBackgroundTask(taskID) }
        }

        do {
            try await BackupManager.shared.performBackup(archive)
        } catch {
            Logger.pageboxd.error("Backup automatico fallito: \(error.localizedDescription, privacy: .public)")
        }
    }
}
