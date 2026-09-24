import OSLog
import SwiftData
import SwiftUI

// MARK: - Chiavi di persistenza delle preferenze

enum AppStorageKeys {
    static let theme = "settings.theme"
    static let hapticsEnabled = "settings.hapticsEnabled"
    static let libraryLayout = "library.layout"
    static let librarySort = "library.sort"
    static let watchlistLayout = "watchlist.layout"
    static let watchlistSort = "watchlist.sort"
    static let googleBooksAPIKey = "catalog.googleBooksAPIKey"
    static let authorNamesMigrated = "migration.authorNames.v1"
}

// MARK: - Logging (solo locale, nessun invio esterno)

extension Logger {
    static let pageboxd = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Pageboxd", category: "app")
}

// MARK: - Localizzazione

extension Locale {
    static let pageboxd = Locale(identifier: "it_IT")
}

extension Calendar {
    static var pageboxd: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = .pageboxd
        return calendar
    }
}

// MARK: - Stringhe

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    var nilIfBlank: String? {
        let value = trimmed
        return value.isEmpty ? nil : value
    }
}

// MARK: - Valutazioni

enum RatingFormatter {
    /// Rappresentazione testuale stile Letterboxd, es. "★★★½".
    static func stars(_ rating: Double) -> String {
        guard rating > 0 else { return "" }
        let full = Int(rating)
        let hasHalf = rating - Double(full) >= 0.5
        return String(repeating: "★", count: full) + (hasHalf ? "½" : "")
    }

    static func spoken(_ rating: Double) -> String {
        guard rating > 0 else { return "Nessuna valutazione" }
        let value = rating.formatted(.number.precision(.fractionLength(0...1)).locale(.pageboxd))
        return "\(value) stelle su 5"
    }
}

// MARK: - Binding

extension Binding where Value == Bool {
    /// Binding booleano che è `true` quando l'opzionale ha un valore; impostarlo a `false` lo azzera.
    init<Wrapped>(isPresent optional: Binding<Wrapped?>) {
        self.init(
            get: { optional.wrappedValue != nil },
            set: { isPresented in
                if !isPresented { optional.wrappedValue = nil }
            }
        )
    }
}

// MARK: - SwiftData

extension ModelContext {
    func saveLogging() {
        guard hasChanges else { return }
        do {
            try save()
        } catch {
            Logger.pageboxd.error("Salvataggio SwiftData fallito: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - Apertura Impostazioni di sistema

enum SystemSettings {
    static func open() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
