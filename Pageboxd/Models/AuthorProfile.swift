import Foundation
import SwiftData

/// Scheda di un autore salvata sul dispositivo, così resta consultabile anche offline.
/// Viene ricostruita dai cataloghi online, quindi non fa parte del backup.
@Model
final class AuthorProfile {
    /// Chiave normalizzata del nome (vedi `TextMatching.authorKey`).
    @Attribute(.unique) var key: String = ""
    var name: String = ""
    var summary: String?
    var bio: String?
    var bioSource: String?
    var sourceURLString: String?
    var birthDate: String?
    var deathDate: String?
    var openLibraryKey: String?
    /// Foto salvata in Documents, percorso relativo (es. "authors/UUID.jpg").
    var photoPath: String?
    var fetchedAt: Date = Date()

    init(key: String, name: String) {
        self.key = key
        self.name = name
    }

    var sourceURL: URL? { sourceURLString.flatMap { URL(string: $0) } }

    /// Le schede più vecchie di 30 giorni vengono aggiornate alla prima apertura con connessione.
    var isStale: Bool { fetchedAt < Date().addingTimeInterval(-30 * 24 * 3600) }

    /// "1963" oppure "1923 – 1985", ricavato dalle date disponibili.
    var lifeSpan: String? {
        let birth = birthDate.flatMap { MetadataParsing.year(from: $0) }
        let death = deathDate.flatMap { MetadataParsing.year(from: $0) }
        switch (birth, death) {
        case let (born?, died?): return "\(born) – \(died)"
        case let (born?, nil): return "n. \(born)"
        case let (nil, died?): return "m. \(died)"
        default: return nil
        }
    }
}

/// Destinazione di navigazione verso la scheda di un autore.
struct AuthorRoute: Hashable {
    let name: String
    var openLibraryKey: String? = nil

    var key: String { TextMatching.authorKey(name) }
}
