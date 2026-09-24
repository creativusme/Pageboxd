import SwiftUI

/// Ricerca per titolo, autore o ISBN su tutti i cataloghi, con risultati progressivi.
/// Con `presetISBN` (libro scansionato ma non trovato) il risultato scelto mantiene l'ISBN della tua copia.
@MainActor
struct BookSearchView: View {
    var presetISBN: String? = nil
    let onSelect: (BookMetadata) -> Void

    private enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case empty
        case failed(String)
    }

    @State private var query = ""
    @State private var results: [BookMetadata] = []
    @State private var phase: Phase = .idle
    @State private var isPreparingSelection = false

    var body: some View {
        List {
            if let presetISBN {
                Section {
                    Label {
                        Text("Cerca il titolo del libro: verrà salvato con l'ISBN della tua copia (\(presetISBN)).")
                            .font(.subheadline)
                    } icon: {
                        Image(systemName: "barcode")
                            .foregroundStyle(Color.pbGreen)
                    }
                }
                .listRowBackground(Color.pbSurface)
            }

            resultsContent
        }
        .listStyle(.insetGrouped)
        .pbFormStyle()
        .safeAreaInset(edge: .top) {
            SearchField(text: $query, prompt: "Titolo, autore o ISBN", autofocus: true)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.pbBackground)
        }
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle("Cerca libro")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if phase == .loading && !results.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    ProgressView()
                }
            }
        }
        .task(id: query) {
            // Breve pausa nella digitazione prima di interrogare i cataloghi.
            let current = query.trimmed
            guard current.count >= 3 else {
                results = []
                phase = .idle
                return
            }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await runSearch(current)
        }
        .overlay {
            if isPreparingSelection {
                ProgressView("Completo i dati del libro…")
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .disabled(isPreparingSelection)
    }

    // MARK: Risultati

    @ViewBuilder
    private var resultsContent: some View {
        switch phase {
        case .idle:
            hint
        case .loading where results.isEmpty:
            HStack {
                Spacer()
                ProgressView("Cerco nei cataloghi…")
                Spacer()
            }
            .padding(.vertical, 32)
            .listRowBackground(Color.clear)
        case .empty:
            ContentUnavailableView.search(text: query)
                .listRowBackground(Color.clear)
        case .failed(let message):
            ContentUnavailableView {
                Label("Ricerca non riuscita", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Riprova") {
                    Task { await runSearch(query.trimmed) }
                }
                .buttonStyle(.bordered)
            }
            .listRowBackground(Color.clear)
        default:
            Section {
                ForEach(results) { metadata in
                    Button {
                        Task { await select(metadata) }
                    } label: {
                        SearchResultRow(metadata: metadata)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.pbSurface)
                }
            } footer: {
                Text("Fonti: biblioteche italiane (SBN), Open Library, Apple Books e Google Books.")
            }
        }
    }

    private var hint: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(Color.pbTextSecondary)
            Text("Scrivi almeno 3 caratteri. Se scrivi il titolo in italiano cerco l'edizione italiana.")
                .font(.subheadline)
                .foregroundStyle(Color.pbTextSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .listRowBackground(Color.clear)
    }

    // MARK: Azioni

    private func runSearch(_ text: String) async {
        guard !text.isEmpty else { return }
        phase = .loading
        do {
            for try await update in BookMetadataFetcher.shared.searchStream(query: text) {
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    results = update.results
                }
                if update.isFinal {
                    phase = update.results.isEmpty ? .empty : .loaded
                }
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            if results.isEmpty {
                phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            } else {
                phase = .loaded
            }
        }
    }

    /// Prima di aprire il modulo completa pagine, trama e copertina dagli altri cataloghi.
    private func select(_ metadata: BookMetadata) async {
        Haptics.impact(.light)
        isPreparingSelection = true
        var chosen = await BookMetadataFetcher.shared.enrich(metadata)
        if let presetISBN {
            chosen.isbn = presetISBN
        }
        isPreparingSelection = false
        onSelect(chosen)
    }
}

// MARK: - Riga risultato

private struct SearchResultRow: View {
    let metadata: BookMetadata

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            AsyncImage(url: metadata.listThumbnailURL, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    CoverPlaceholderView(title: metadata.title, author: metadata.authorLine)
                }
            }
            .frame(width: 52, height: 78)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(metadata.title)
                    .font(.headline)
                    .foregroundStyle(Color.primary)
                    .lineLimit(2)
                if !metadata.authorLine.isEmpty {
                    Text(metadata.authorLine)
                        .font(.subheadline)
                        .foregroundStyle(Color.pbTextSecondary)
                        .lineLimit(1)
                }
                if !editionLine.isEmpty {
                    Text(editionLine)
                        .font(.caption)
                        .foregroundStyle(Color.pbTextSecondary)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    if let language = metadata.languageCode {
                        tag(language.uppercased(), tint: ReadingLanguage.from(isoCode: language)?.tint ?? .pbOrange)
                    }
                    tag(metadata.source.shortName, tint: .pbTextSecondary)
                    if let isbn = metadata.isbn {
                        Text(isbn)
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(Color.pbTextSecondary)
                    }
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "plus.circle.fill")
                .font(.title3)
                .foregroundStyle(Color.pbGreen)
                .padding(.top, 2)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    /// "Piemme · 2003 · 379 pag."
    private var editionLine: String {
        [
            metadata.publisher,
            metadata.publicationYear.map { String($0) },
            metadata.pageCount.map { "\($0) pag." }
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }

    private func tag(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .heavy))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .foregroundStyle(tint)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 3))
    }
}
