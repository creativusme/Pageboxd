import SwiftData
import SwiftUI

@main
struct PageboxdApp: App {
    private let containerResult: Result<ModelContainer, Error>

    init() {
        ThemeManager.configureAppearance()
        do {
            let schema = Schema([BookItem.self, ReadingLog.self, AuthorProfile.self])
            let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
            containerResult = .success(try ModelContainer(for: schema, configurations: [configuration]))
        } catch {
            containerResult = .failure(error)
        }
    }

    var body: some Scene {
        WindowGroup {
            switch containerResult {
            case .success(let container):
                RootView()
                    .modelContainer(container)
            case .failure(let error):
                DatabaseErrorView(error: error)
            }
        }
    }
}

// MARK: - Tab bar principale

enum AppTab: Hashable {
    case library
    case watchlist
    case add
    case stats
    case settings
}

@MainActor
struct RootView: View {
    @AppStorage(AppStorageKeys.theme) private var themeRaw = AppTheme.system.rawValue
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: AppTab = .library

    private var theme: AppTheme { AppTheme(rawValue: themeRaw) ?? .system }

    var body: some View {
        TabView(selection: $selectedTab) {
            LibraryView(onAddBook: { selectedTab = .add })
                .tabItem { Label("Libreria", systemImage: "books.vertical.fill") }
                .tag(AppTab.library)

            WatchlistView(onAddBook: { selectedTab = .add })
                .tabItem { Label("Da leggere", systemImage: "bookmark.fill") }
                .tag(AppTab.watchlist)

            AddBookHubView { book in
                selectedTab = book.status == .watchlist ? .watchlist : .library
            }
            .tabItem { Label("Aggiungi", systemImage: "plus.circle.fill") }
            .tag(AppTab.add)

            StatsView()
                .tabItem { Label("Statistiche", systemImage: "chart.bar.xaxis") }
                .tag(AppTab.stats)

            SettingsView()
                .tabItem { Label("Impostazioni", systemImage: "gearshape.fill") }
                .tag(AppTab.settings)
        }
        .tint(.pbGreen)
        .environment(\.locale, .pageboxd)
        .preferredColorScheme(theme.colorScheme)
        .onAppear { ThemeManager.apply(theme) }
        .onChange(of: themeRaw) { ThemeManager.apply(theme) }
        .onChange(of: selectedTab) { Haptics.selection() }
        .task { AuthorMigration.runIfNeeded(in: modelContext) }
        // Backup automatico: poco dopo ogni salvataggio e subito quando l'app va in background.
        .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { _ in
            AutoBackup.schedule(context: modelContext)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                AutoBackup.schedule(context: modelContext, after: .zero)
            }
        }
    }
}

// MARK: - Errore di apertura del database

struct DatabaseErrorView: View {
    let error: Error

    var body: some View {
        ContentUnavailableView {
            Label("Impossibile aprire la libreria", systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            Text("Si è verificato un problema con l'archivio locale. I tuoi dati non sono stati modificati. Prova a riavviare l'app o ad aggiornarla.\n\n\(error.localizedDescription)")
        }
        .background(Color.pbBackground)
    }
}
