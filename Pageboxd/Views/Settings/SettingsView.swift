import SwiftData
import SwiftUI
import UIKit

@MainActor
struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \BookItem.title) private var books: [BookItem]

    @AppStorage(AppStorageKeys.theme) private var themeRaw = AppTheme.system.rawValue
    @AppStorage(AppStorageKeys.hapticsEnabled) private var hapticsEnabled = true
    @AppStorage(AppStorageKeys.googleBooksAPIKey) private var googleAPIKey = ""
    @State private var isTestingGoogleKey = false
    @State private var googleKeyMessage: String? = nil

    @State private var exportedFile: ExportedFile? = nil
    @State private var isExporting = false
    @State private var photoUsage: StorageUsage? = nil
    @State private var databaseBytes: Int64? = nil
    @State private var isOptimizing = false
    @State private var isConfirmingOptimization = false
    @State private var cleanupReport: StorageCleanupReport? = nil
    @State private var errorMessage: String? = nil
    @State private var backupStatus = BackupStatus()
    @State private var isBackingUp = false
    @State private var backupMessage: String? = nil

    struct BackupStatus {
        var folderName: String?
        var lastBackup: Date?
        var lastError: String?

        static func current() -> BackupStatus {
            let manager = BackupManager.shared
            return BackupStatus(
                folderName: manager.folderDisplayName,
                lastBackup: manager.lastBackupDate,
                lastError: manager.lastErrorMessage
            )
        }
    }

    struct ExportedFile: Identifiable {
        let id = UUID()
        let url: URL
    }

    private var referencedPaths: Set<String> {
        Set(books.flatMap { [$0.photoPath, $0.remoteCoverPath].compactMap { $0 } })
    }

    var body: some View {
        NavigationStack {
            Form {
                autoBackupSection
                appearanceSection
                catalogsSection
                backupSection
                storageSection
                privacySection
                aboutSection
            }
            .pbFormStyle()
            .navigationTitle("Impostazioni")
            .task(id: books.count) {
                backupStatus = .current()
                await refreshStorage()
            }
            .sheet(item: $exportedFile) { file in
                ActivityView(activityItems: [file.url])
                    .presentationDetents([.medium, .large])
                    .ignoresSafeArea()
            }
            .confirmationDialog("Ottimizzare l'archivio?", isPresented: $isConfirmingOptimization, titleVisibility: .visible) {
                Button("Ottimizza e pulisci") {
                    Task { await optimizeStorage() }
                }
                Button("Annulla", role: .cancel) {}
            } message: {
                Text("Verranno eliminate le foto non più collegate a nessun libro, ricompresse quelle troppo pesanti e svuotati cache e file temporanei. Le foto dei tuoi libri restano intatte.")
            }
            .alert("Ottimizzazione completata", isPresented: Binding(isPresent: $cleanupReport), presenting: cleanupReport) { _ in
                Button("OK", role: .cancel) {}
            } message: { report in
                Text(cleanupSummary(report))
            }
            .alert("Backup", isPresented: Binding(isPresent: $backupMessage)) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(backupMessage ?? "")
            }
            .alert("Google Books", isPresented: Binding(isPresent: $googleKeyMessage)) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(googleKeyMessage ?? "")
            }
            .alert("Errore", isPresented: Binding(isPresent: $errorMessage)) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    // MARK: Backup automatico

    private var autoBackupSection: some View {
        Section {
            HStack {
                Label("Cartella", systemImage: "folder.fill")
                Spacer()
                Text(backupStatus.folderName ?? "Non configurata")
                    .foregroundStyle(backupStatus.folderName == nil ? Color.pbOrange : Color.pbTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if let lastBackup = backupStatus.lastBackup {
                HStack {
                    Label("Ultimo backup", systemImage: "clock.arrow.circlepath")
                    Spacer()
                    Text(lastBackup.formatted(.relative(presentation: .named).locale(.pageboxd)))
                        .foregroundStyle(Color.pbTextSecondary)
                }
            }

            if let lastError = backupStatus.lastError {
                Label(lastError, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Color.pbOrange)
            }

            BackupConnectButton(onChange: { backupStatus = .current() }) {
                Label(
                    backupStatus.folderName == nil ? "Scegli cartella di backup" : "Cambia cartella o ripristina",
                    systemImage: "folder.badge.plus"
                )
            }

            if backupStatus.folderName != nil {
                Button {
                    Task { await backupNow() }
                } label: {
                    HStack {
                        Label("Esegui backup ora", systemImage: "arrow.clockwise.icloud")
                        Spacer()
                        if isBackingUp {
                            ProgressView()
                        }
                    }
                }
                .disabled(isBackingUp)

                Button(role: .destructive) {
                    BackupManager.shared.disconnectFolder()
                    backupStatus = .current()
                    Haptics.impact(.light)
                } label: {
                    Label("Scollega cartella", systemImage: "folder.badge.minus")
                }
            }
        } header: {
            Text("Backup automatico")
        } footer: {
            Text("Scegli una cartella in iCloud Drive (o su una chiavetta/altra app): libri e foto vengono copiati lì a ogni modifica. Se reinstalli o cancelli l'app, scegli di nuovo la stessa cartella per ripristinare tutto.")
        }
        .listRowBackground(Color.pbSurface)
    }

    private func backupNow() async {
        isBackingUp = true
        defer { isBackingUp = false }
        await AutoBackup.run(context: modelContext)
        backupStatus = .current()
        if let error = backupStatus.lastError {
            Haptics.error()
            backupMessage = "Backup non riuscito: \(error)"
        } else if books.isEmpty {
            backupMessage = "La libreria è vuota: nessun backup da salvare."
        } else {
            Haptics.success()
            backupMessage = "Backup completato: \(books.count) libri salvati."
        }
    }

    // MARK: Aspetto

    private var appearanceSection: some View {
        Section {
            Picker("Tema", selection: $themeRaw) {
                ForEach(AppTheme.allCases) { theme in
                    Text(theme.displayName).tag(theme.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: themeRaw) { Haptics.selection() }

            Toggle(isOn: $hapticsEnabled) {
                Label("Feedback aptico", systemImage: "hand.tap")
            }
            .tint(.pbGreen)
        } header: {
            Text("Aspetto")
        }
        .listRowBackground(Color.pbSurface)
    }

    // MARK: Cataloghi online

    private var catalogsSection: some View {
        Section {
            catalogRow("Biblioteche italiane (SBN)", detail: "Tutti i libri pubblicati in Italia", systemImage: "building.columns")
            catalogRow("Open Library", detail: "Catalogo internazionale e autori", systemImage: "books.vertical")
            catalogRow("Apple Books", detail: "Copertine e trame, edizioni italiane", systemImage: "book")
            catalogRow(
                "Google Books",
                detail: googleAPIKey.trimmed.isEmpty ? "Senza chiave: usato solo quando Google lo consente" : "Attivo con la tua chiave",
                systemImage: "globe"
            )

            SecureField("Chiave API Google Books (facoltativa)", text: $googleAPIKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            if !googleAPIKey.trimmed.isEmpty {
                Button {
                    Task { await testGoogleKey() }
                } label: {
                    HStack {
                        Label("Verifica chiave", systemImage: "checkmark.seal")
                        Spacer()
                        if isTestingGoogleKey {
                            ProgressView()
                        }
                    }
                }
                .disabled(isTestingGoogleKey)
            }
        } header: {
            Text("Cataloghi online")
        } footer: {
            Text("Libri e ricerche usano tutte le fonti insieme. Google Books senza chiave è spesso bloccato: una chiave gratuita (console.cloud.google.com › crea un progetto › abilita \"Books API\" › Credenziali › Chiave API) consente 1.000 ricerche al giorno. Resta solo su questo iPhone.")
        }
        .listRowBackground(Color.pbSurface)
    }

    private func catalogRow(_ title: String, detail: String, systemImage: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(Color.pbGreen)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Color.pbTextSecondary)
            }
        }
    }

    private func testGoogleKey() async {
        isTestingGoogleKey = true
        defer { isTestingGoogleKey = false }
        do {
            _ = try await BookMetadataFetcher.shared.googleLookup(isbn: "9788845292613")
            Haptics.success()
            googleKeyMessage = "La chiave funziona: Google Books è attivo."
        } catch MetadataFetchError.notFound {
            Haptics.success()
            googleKeyMessage = "La chiave funziona: Google Books è attivo."
        } catch {
            Haptics.error()
            googleKeyMessage = "La chiave non è stata accettata. Controlla di averla copiata per intero e di aver abilitato \"Books API\" nel progetto."
        }
    }

    // MARK: Backup

    private var backupSection: some View {
        Section {
            Button {
                exportCSV()
            } label: {
                HStack {
                    Label("Esporta dati in CSV", systemImage: "square.and.arrow.up")
                    Spacer()
                    if isExporting {
                        ProgressView()
                    }
                }
            }
            .disabled(isExporting || books.isEmpty)
        } header: {
            Text("Backup e dati")
        } footer: {
            Text("Il file include titolo, autore, ISBN, valutazione, cuore, lingua, date di lettura e recensione di tutti i \(books.count) libri. Puoi salvarlo in File, inviarlo o aprirlo con Numbers ed Excel.")
        }
        .listRowBackground(Color.pbSurface)
    }

    // MARK: Archiviazione

    private var storageSection: some View {
        Section {
            storageRow(
                "Foto salvate",
                value: photoUsage.map { "\($0.fileCount) · \(formatBytes($0.bytes))" },
                systemImage: "photo.stack"
            )
            storageRow(
                "Database",
                value: databaseBytes.map { formatBytes($0) },
                systemImage: "cylinder.split.1x2"
            )
            if let orphans = photoUsage?.orphanCount, orphans > 0 {
                storageRow(
                    "Foto non collegate",
                    value: "\(orphans)",
                    systemImage: "exclamationmark.triangle"
                )
            }

            Button {
                isConfirmingOptimization = true
            } label: {
                HStack {
                    Label("Pulisci e ottimizza", systemImage: "sparkles")
                    Spacer()
                    if isOptimizing {
                        ProgressView()
                    }
                }
            }
            .disabled(isOptimizing)
        } header: {
            Text("Archiviazione")
        } footer: {
            Text("Le foto sono salvate solo nella cartella Documenti dell'app, ridimensionate a max 1080 px e compresse in JPEG.")
        }
        .listRowBackground(Color.pbSurface)
    }

    private func storageRow(_ title: String, value: String?, systemImage: String) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            if let value {
                Text(value)
                    .monospacedDigit()
                    .foregroundStyle(Color.pbTextSecondary)
            } else {
                ProgressView()
            }
        }
    }

    // MARK: Privacy e info

    private var privacySection: some View {
        Section {
            privacyRow("100% offline", detail: "Libri, foto e recensioni restano su questo iPhone.", systemImage: "iphone")
            privacyRow("Nessun tracciamento", detail: "Nessun account, nessuna analitica, nessun SDK di terze parti.", systemImage: "eye.slash")
            privacyRow("Cataloghi pubblici", detail: "Solo quando cerchi un libro o un autore l'ISBN o il testo vengono inviati ai cataloghi (SBN, Open Library, Apple Books, Google Books, Wikipedia).", systemImage: "network")
        } header: {
            Text("Privacy")
        }
        .listRowBackground(Color.pbSurface)
    }

    private func privacyRow(_ title: String, detail: String, systemImage: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.pbGreen)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(Color.pbTextSecondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var aboutSection: some View {
        Section {
            HStack {
                Text("Versione")
                Spacer()
                Text(appVersion)
                    .foregroundStyle(Color.pbTextSecondary)
            }
        } header: {
            Text("Info")
        } footer: {
            Text("Pageboxd — il diario delle tue edizioni fisiche.")
                .frame(maxWidth: .infinity)
                .padding(.top, 16)
        }
        .listRowBackground(Color.pbSurface)
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    // MARK: Azioni

    private func exportCSV() {
        let rows = books.map(CSVExporter.Row.init(book:))
        isExporting = true
        Task {
            defer { isExporting = false }
            do {
                let url = try await CSVExporter.writeCSV(rows: rows)
                Haptics.success()
                exportedFile = ExportedFile(url: url)
            } catch {
                Haptics.error()
                errorMessage = "Esportazione non riuscita: \(error.localizedDescription)"
            }
        }
    }

    private func refreshStorage() async {
        let paths = referencedPaths
        photoUsage = await ImageStorageManager.shared.usage(referencedPaths: paths)
        databaseBytes = await ImageStorageManager.shared.databaseSize()
    }

    private func optimizeStorage() async {
        isOptimizing = true
        defer { isOptimizing = false }
        let report = await ImageStorageManager.shared.performMaintenance(referencedPaths: referencedPaths)
        await refreshStorage()
        Haptics.success()
        cleanupReport = report
    }

    private func cleanupSummary(_ report: StorageCleanupReport) -> String {
        var parts: [String] = []
        parts.append(report.removedOrphans == 1 ? "1 foto orfana rimossa" : "\(report.removedOrphans) foto orfane rimosse")
        parts.append(report.optimizedImages == 1 ? "1 foto ricompressa" : "\(report.optimizedImages) foto ricompresse")
        parts.append("Spazio liberato: \(formatBytes(report.bytesFreed))")
        return parts.joined(separator: "\n")
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - Share sheet nativo

struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
