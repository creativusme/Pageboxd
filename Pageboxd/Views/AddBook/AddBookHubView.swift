import SwiftData
import SwiftUI

/// Tab "Aggiungi": scansione ISBN, ricerca online o inserimento manuale.
@MainActor
struct AddBookHubView: View {
    var onBookSaved: (BookItem) -> Void

    @Environment(\.modelContext) private var modelContext

    @State private var isShowingScanner = false
    @State private var isShowingSearch = false
    @State private var scannedISBN: String? = nil
    @State private var formRequest: FormRequest? = nil
    @State private var duplicate: DuplicateMatch? = nil
    @State private var fetchTask: Task<Void, Never>? = nil
    @State private var isFetching = false
    @State private var notFound: NotFoundInfo? = nil
    /// ISBN scansionato da mantenere quando si cerca il libro per titolo.
    @State private var searchPresetISBN: String? = nil

    struct NotFoundInfo: Identifiable {
        let id = UUID()
        let isbn: String
        let reason: String
    }

    struct FormRequest: Identifiable {
        let id = UUID()
        let draft: BookDraft
        let notice: String?
    }

    struct DuplicateMatch: Identifiable {
        let id = UUID()
        let isbn: String
        let title: String
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Registra la tua copia fisica: scansiona il codice a barre, cercala nei cataloghi online o inseriscila a mano. Potrai sempre fotografare la tua edizione.")
                        .font(.subheadline)
                        .foregroundStyle(Color.pbTextSecondary)
                        .padding(.bottom, 4)

                    Button {
                        Haptics.impact(.light)
                        isShowingScanner = true
                    } label: {
                        OptionCard(
                            title: "Scansiona codice a barre",
                            subtitle: "Inquadra l'ISBN sul retro del libro",
                            systemImage: "barcode.viewfinder",
                            tint: .pbGreen,
                            isProminent: true
                        )
                    }
                    .buttonStyle(.plain)

                    Button {
                        Haptics.impact(.light)
                        searchPresetISBN = nil
                        isShowingSearch = true
                    } label: {
                        OptionCard(
                            title: "Cerca per titolo o autore",
                            subtitle: "Biblioteche italiane, Open Library, Apple Books",
                            systemImage: "magnifyingglass",
                            tint: .pbBlue
                        )
                    }
                    .buttonStyle(.plain)

                    NavigationLink(value: AuthorSearchRoute()) {
                        OptionCard(
                            title: "Esplora autori",
                            subtitle: "Biografia, foto e tutti i libri di un autore",
                            systemImage: "person.crop.rectangle.stack",
                            tint: .pbGreen
                        )
                    }
                    .buttonStyle(.plain)

                    Button {
                        Haptics.impact(.light)
                        formRequest = FormRequest(draft: BookDraft(), notice: nil)
                    } label: {
                        OptionCard(
                            title: "Aggiungi manualmente",
                            subtitle: "Compila tu tutti i dettagli",
                            systemImage: "square.and.pencil",
                            tint: .pbOrange
                        )
                    }
                    .buttonStyle(.plain)

                    Label {
                        Text("Le ricerche inviano ai cataloghi solo l'ISBN o il testo cercato. Libri, foto e recensioni restano esclusivamente su questo iPhone.")
                    } icon: {
                        Image(systemName: "lock.shield")
                    }
                    .font(.footnote)
                    .foregroundStyle(Color.pbTextSecondary)
                    .padding(.top, 12)
                }
                .padding(16)
            }
            .background(Color.pbBackground)
            .navigationTitle("Aggiungi")
            .pageboxdDestinations()
            .navigationDestination(isPresented: $isShowingSearch) {
                BookSearchView(presetISBN: searchPresetISBN) { metadata in
                    formRequest = FormRequest(
                        draft: BookDraft(metadata: metadata),
                        notice: "Dati da \(metadata.source.rawValue). Puoi modificarli e aggiungere la foto della tua edizione."
                    )
                }
            }
            .confirmationDialog(
                "Libro non trovato",
                isPresented: Binding(isPresent: $notFound),
                titleVisibility: .visible,
                presenting: notFound
            ) { info in
                Button("Cerca per titolo o autore") {
                    searchPresetISBN = info.isbn
                    isShowingSearch = true
                }
                Button("Inserisci manualmente") {
                    formRequest = FormRequest(
                        draft: BookDraft(isbn: info.isbn),
                        notice: "Completa i dati a mano: l'ISBN \(info.isbn) è già inserito."
                    )
                }
                Button("Riprova") { startFetch(isbn: info.isbn) }
                Button("Scansiona di nuovo") { isShowingScanner = true }
                Button("Annulla", role: .cancel) {}
            } message: { info in
                Text("\(info.reason) ISBN \(info.isbn). Puoi cercarlo per titolo mantenendo il tuo ISBN, oppure inserirlo a mano.")
            }
            .fullScreenCover(isPresented: $isShowingScanner, onDismiss: handleScannerDismissed) {
                BarcodeScannerView { isbn in
                    scannedISBN = isbn
                }
            }
            .sheet(item: $formRequest) { request in
                AddEditBookView(mode: .create(request.draft), notice: request.notice) { book in
                    isShowingSearch = false
                    onBookSaved(book)
                }
            }
            .alert(
                "Già nella tua libreria",
                isPresented: Binding(isPresent: $duplicate),
                presenting: duplicate
            ) { match in
                Button("Aggiungi comunque") { startFetch(isbn: match.isbn) }
                Button("Annulla", role: .cancel) {}
            } message: { match in
                Text("Hai già registrato \"\(match.title)\". Vuoi aggiungere un'altra copia o edizione?")
            }
            .overlay {
                if isFetching {
                    fetchingOverlay
                }
            }
        }
    }

    // MARK: Overlay di caricamento

    private var fetchingOverlay: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                Text("Cerco il libro nei cataloghi…")
                    .font(.subheadline.weight(.medium))
                Button("Annulla", role: .cancel) {
                    fetchTask?.cancel()
                    fetchTask = nil
                    isFetching = false
                }
                .buttonStyle(.bordered)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .transition(.opacity)
    }

    // MARK: Flusso di scansione

    /// Avviato solo a scanner chiuso, per evitare conflitti tra presentazioni modali.
    private func handleScannerDismissed() {
        guard let isbn = scannedISBN else { return }
        scannedISBN = nil

        if let existing = existingBook(isbn: isbn) {
            Haptics.warning()
            duplicate = DuplicateMatch(isbn: isbn, title: existing.title)
            return
        }
        startFetch(isbn: isbn)
    }

    private func existingBook(isbn: String) -> BookItem? {
        let target: String? = isbn
        var descriptor = FetchDescriptor<BookItem>(predicate: #Predicate { $0.isbn == target })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    private func startFetch(isbn: String) {
        fetchTask?.cancel()
        withAnimation { isFetching = true }

        fetchTask = Task {
            do {
                let metadata = try await BookMetadataFetcher.shared.fetch(isbn: isbn)
                guard !Task.isCancelled else { return }
                withAnimation { isFetching = false }
                Haptics.success()
                formRequest = FormRequest(
                    draft: BookDraft(metadata: metadata),
                    notice: "Trovato su \(metadata.source.rawValue). Scatta una foto alla tua copia per renderla unica."
                )
            } catch is CancellationError {
                withAnimation { isFetching = false }
            } catch {
                guard !Task.isCancelled else { return }
                withAnimation { isFetching = false }
                Haptics.warning()
                let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                notFound = NotFoundInfo(isbn: isbn, reason: reason)
            }
        }
    }
}

// MARK: - Card opzione

private struct OptionCard: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    var isProminent = false

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(isProminent ? Color.pbBackground : tint)
                .frame(width: 54, height: 54)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(isProminent ? tint : tint.opacity(0.15))
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Color.primary)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Color.pbTextSecondary)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.bold))
                .foregroundStyle(Color.pbTextSecondary)
        }
        .pbCard(cornerRadius: 18)
        .contentShape(Rectangle())
    }
}
