import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Fa scegliere una cartella nell'app File (consigliato iCloud Drive) e la usa per i backup automatici.
/// Se la cartella contiene già un backup Pageboxd con libri mancanti, propone il ripristino.
@MainActor
struct BackupConnectButton<Content: View>: View {
    private let label: () -> Content
    private let onChange: (() -> Void)?

    @Environment(\.modelContext) private var modelContext

    @State private var isPickingFolder = false
    @State private var foundArchive: BackupArchive? = nil
    @State private var isWorking = false
    @State private var message: String? = nil

    init(onChange: (() -> Void)? = nil, @ViewBuilder label: @escaping () -> Content) {
        self.label = label
        self.onChange = onChange
    }

    var body: some View {
        Button {
            isPickingFolder = true
        } label: {
            HStack {
                label()
                if isWorking {
                    Spacer()
                    ProgressView()
                }
            }
        }
        .disabled(isWorking)
        .fileImporter(isPresented: $isPickingFolder, allowedContentTypes: [.folder]) { result in
            handlePickedFolder(result)
        }
        .confirmationDialog(
            "Backup trovato",
            isPresented: Binding(isPresent: $foundArchive),
            titleVisibility: .visible,
            presenting: foundArchive
        ) { archive in
            Button("Ripristina \(missingBooksCount(in: archive)) libri") {
                Task { await restore(archive) }
            }
            Button("Non ripristinare", role: .cancel) {}
        } message: { archive in
            Text("Backup del \(archive.exportedAt.formatted(.dateTime.day().month(.wide).year().hour().minute().locale(.pageboxd))). I libri già presenti non verranno duplicati. Se non ripristini, il prossimo backup sostituirà questo (la versione precedente resta in library.previous.json).")
        }
        .alert("Backup", isPresented: Binding(isPresent: $message)) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }

    // MARK: Azioni

    private func handlePickedFolder(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            message = error.localizedDescription
        case .success(let url):
            isWorking = true
            Task {
                defer {
                    isWorking = false
                    onChange?()
                }
                do {
                    if let archive = try await BackupManager.shared.connectFolder(url),
                       missingBooksCount(in: archive) > 0 {
                        foundArchive = archive
                    } else {
                        await AutoBackup.run(context: modelContext)
                        Haptics.success()
                        message = "Cartella collegata. Da ora ogni modifica viene salvata automaticamente anche lì."
                    }
                } catch {
                    Haptics.error()
                    message = "Impossibile usare questa cartella: \(error.localizedDescription)"
                }
            }
        }
    }

    private func missingBooksCount(in archive: BackupArchive) -> Int {
        let existingIDs = Set(((try? modelContext.fetch(FetchDescriptor<BookItem>())) ?? []).map(\.id))
        return archive.books.filter { !existingIDs.contains($0.id) }.count
    }

    private func restore(_ archive: BackupArchive) async {
        isWorking = true
        defer {
            isWorking = false
            onChange?()
        }
        do {
            try await BackupManager.shared.restoreImages(for: archive)
            let result = try BackupManager.importArchive(archive, into: modelContext)
            Haptics.success()
            message = result.imported == 1
                ? "1 libro ripristinato."
                : "\(result.imported) libri ripristinati."
            AutoBackup.schedule(context: modelContext, after: .seconds(1))
        } catch {
            Haptics.error()
            message = "Ripristino non riuscito: \(error.localizedDescription)"
        }
    }
}
