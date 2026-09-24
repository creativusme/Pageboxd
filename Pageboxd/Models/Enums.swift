import SwiftUI
import UIKit

// MARK: - Lingua di lettura

enum ReadingLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case italian = "it"
    case english = "en"
    case other = "other"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .italian: return "Italiano"
        case .english: return "Inglese"
        case .other: return "Altro"
        }
    }

    var shortCode: String {
        switch self {
        case .italian: return "IT"
        case .english: return "EN"
        case .other: return "ALTRO"
        }
    }

    var flag: String {
        switch self {
        case .italian: return "🇮🇹"
        case .english: return "🇬🇧"
        case .other: return "🌐"
        }
    }

    var tint: Color {
        switch self {
        case .italian: return .pbGreen
        case .english: return .pbBlue
        case .other: return .pbOrange
        }
    }

    /// Converte un codice lingua ISO 639-1/639-2 (es. "it", "ita", "en", "eng") restituito dalle API.
    static func from(isoCode: String?) -> ReadingLanguage? {
        guard let code = isoCode?.trimmed.lowercased(), !code.isEmpty else { return nil }
        switch String(code.prefix(2)) {
        case "it": return .italian
        case "en": return .english
        default: return .other
        }
    }
}

// MARK: - Catalogo lingue (per "Altro")

enum LanguageCatalog {
    /// Lingue proposte in cima all'elenco.
    static let commonCodes = ["fr", "es", "de", "pt", "ru", "ja", "zh", "ko", "ar", "nl", "sv", "el", "la", "pl", "ca"]

    /// Tutte le lingue ISO 639-1 con il nome in italiano, in ordine alfabetico.
    static let all: [(code: String, name: String)] = {
        let excluded: Set<String> = ["it", "en"]
        let codes = Locale.LanguageCode.isoLanguageCodes
            .map(\.identifier)
            .filter { $0.count == 2 && !excluded.contains($0) }
        return Set(codes)
            .compactMap { code in name(for: code).map { (code: code, name: $0) } }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }()

    static func name(for code: String?) -> String? {
        guard let code = code?.nilIfBlank,
              let name = Locale.pageboxd.localizedString(forLanguageCode: code)
        else { return nil }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// Normalizza codici a 2 o 3 lettere (es. "fra" → "fr").
    static func normalizedCode(_ raw: String?) -> String? {
        guard let raw = raw?.trimmed.lowercased(), !raw.isEmpty else { return nil }
        let language = Locale.Language(identifier: raw)
        let code = language.languageCode?.identifier(.alpha2) ?? language.languageCode?.identifier ?? raw
        return name(for: code) != nil ? code : nil
    }
}

// MARK: - Stato di lettura

enum ReadingStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case read
    case reading
    case watchlist

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .read: return "Letto"
        case .reading: return "In lettura"
        case .watchlist: return "Da leggere"
        }
    }

    var systemImage: String {
        switch self {
        case .read: return "checkmark.circle.fill"
        case .reading: return "book.fill"
        case .watchlist: return "bookmark.fill"
        }
    }

    var tint: Color {
        switch self {
        case .read: return .pbGreen
        case .reading: return .pbBlue
        case .watchlist: return .pbOrange
        }
    }
}

// MARK: - Tema

enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "Sistema"
        case .light: return "Chiaro"
        case .dark: return "Scuro"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var userInterfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: return .unspecified
        case .light: return .light
        case .dark: return .dark
        }
    }
}

// MARK: - Layout e filtri

enum LibraryLayout: String, CaseIterable, Identifiable {
    case grid
    case diary
    case authors

    var id: String { rawValue }

    var title: String {
        switch self {
        case .grid: return "Copertine"
        case .diary: return "Diario"
        case .authors: return "Autori"
        }
    }

    var systemImage: String {
        switch self {
        case .grid: return "square.grid.3x3.fill"
        case .diary: return "list.bullet.rectangle"
        case .authors: return "person.2.fill"
        }
    }
}

enum CollectionLayout: String, CaseIterable, Identifiable {
    case grid
    case list

    var id: String { rawValue }

    var title: String {
        switch self {
        case .grid: return "Griglia"
        case .list: return "Lista"
        }
    }

    var systemImage: String {
        switch self {
        case .grid: return "square.grid.3x3"
        case .list: return "list.bullet"
        }
    }
}

enum LibrarySort: String, CaseIterable, Identifiable {
    case readDate
    case title
    case rating
    case dateAdded

    var id: String { rawValue }

    var title: String {
        switch self {
        case .readDate: return "Data di lettura"
        case .title: return "Titolo"
        case .rating: return "Valutazione"
        case .dateAdded: return "Aggiunti di recente"
        }
    }

    var systemImage: String {
        switch self {
        case .readDate: return "calendar"
        case .title: return "textformat"
        case .rating: return "star"
        case .dateAdded: return "clock"
        }
    }
}

enum WatchlistSort: String, CaseIterable, Identifiable {
    case dateAdded
    case title
    case author

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dateAdded: return "Aggiunti di recente"
        case .title: return "Titolo"
        case .author: return "Autore"
        }
    }
}

enum LanguageFilter: String, CaseIterable, Identifiable {
    case all
    case italian
    case english
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "Tutti"
        case .italian: return "IT"
        case .english: return "EN"
        case .other: return "Altro"
        }
    }

    func matches(_ language: ReadingLanguage) -> Bool {
        switch self {
        case .all: return true
        case .italian: return language == .italian
        case .english: return language == .english
        case .other: return language == .other
        }
    }
}

enum RatingFilter: String, CaseIterable, Identifiable {
    case any
    case fiveStars
    case fourPlus
    case threePlus
    case twoOrLess
    case unrated

    var id: String { rawValue }

    var title: String {
        switch self {
        case .any: return "Tutte le valutazioni"
        case .fiveStars: return "★★★★★"
        case .fourPlus: return "★★★★ e più"
        case .threePlus: return "★★★ e più"
        case .twoOrLess: return "★★ o meno"
        case .unrated: return "Senza voto"
        }
    }

    var chipTitle: String {
        switch self {
        case .any: return "Voto"
        case .fiveStars: return "5★"
        case .fourPlus: return "4★+"
        case .threePlus: return "3★+"
        case .twoOrLess: return "≤2★"
        case .unrated: return "Senza voto"
        }
    }

    func matches(_ rating: Double) -> Bool {
        switch self {
        case .any: return true
        case .fiveStars: return rating >= 5
        case .fourPlus: return rating >= 4
        case .threePlus: return rating >= 3
        case .twoOrLess: return rating > 0 && rating <= 2
        case .unrated: return rating == 0
        }
    }
}
