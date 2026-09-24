import SwiftData
import SwiftUI

@MainActor
struct WatchlistView: View {
    var onAddBook: () -> Void

    @Environment(\.modelContext) private var modelContext

    @Query(
        filter: #Predicate<BookItem> { $0.statusRaw == "watchlist" },
        sort: \BookItem.dateAdded,
        order: .reverse
    )
    private var books: [BookItem]

    @AppStorage(AppStorageKeys.watchlistLayout) private var layoutRaw = CollectionLayout.grid.rawValue
    @AppStorage(AppStorageKeys.watchlistSort) private var sortRaw = WatchlistSort.dateAdded.rawValue

    @State private var searchText = ""
    @State private var bookToMarkAsRead: BookItem? = nil
    @State private var bookPendingDeletion: BookItem? = nil

    private let gridColumns = Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: 3)

    private var layout: CollectionLayout { CollectionLayout(rawValue: layoutRaw) ?? .grid }
    private var sort: WatchlistSort { WatchlistSort(rawValue: sortRaw) ?? .dateAdded }

    private var visibleBooks: [BookItem] {
        let query = searchText.trimmed
        let filtered = query.isEmpty ? books : books.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.author.localizedCaseInsensitiveContains(query)
        }
        switch sort {
        case .dateAdded:
            return filtered
        case .title:
            return filtered.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .author:
            return filtered.sorted {
                let comparison = $0.author.localizedStandardCompare($1.author)
                if comparison != .orderedSame { return comparison == .orderedAscending }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
        }
    }

    var body: some View {
        NavigationStack {
            // Il contenitore che scorre resta sempre lo stesso anche quando la ricerca non trova nulla:
            // il campo di ricerca fa parte del contenuto e non può restare "sospeso" sopra la pagina.
            Group {
                if books.isEmpty {
                    emptyState
                } else {
                    switch layout {
                    case .grid: gridContent
                    case .list: listContent
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.pbBackground)
            .navigationTitle("Da leggere")
            .toolbar { toolbarContent }
            .pageboxdDestinations()
            .sheet(item: $bookToMarkAsRead) { book in
                AddEditBookView(mode: .markAsRead(book))
            }
            .confirmationDialog(
                "Rimuovere dalla watchlist?",
                isPresented: Binding(isPresent: $bookPendingDeletion),
                titleVisibility: .visible,
                presenting: bookPendingDeletion
            ) { book in
                Button("Elimina", role: .destructive) {
                    Haptics.warning()
                    book.deleteWithAssets(from: modelContext)
                }
            } message: { book in
                Text("\"\(book.title)\" verrà eliminato definitivamente.")
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Picker("Ordina per", selection: $sortRaw) {
                    ForEach(WatchlistSort.allCases) { option in
                        Text(option.title).tag(option.rawValue)
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .accessibilityLabel("Ordina")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                layoutRaw = (layout == .grid ? CollectionLayout.list : .grid).rawValue
                Haptics.selection()
            } label: {
                Image(systemName: layout == .grid ? CollectionLayout.list.systemImage : CollectionLayout.grid.systemImage)
            }
            .accessibilityLabel(layout == .grid ? "Mostra come lista" : "Mostra come griglia")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button(action: onAddBook) {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Aggiungi libro")
        }
    }

    // MARK: Stati

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Nessun libro da leggere", systemImage: "bookmark")
        } description: {
            Text("Aggiungi i libri che vuoi leggere impostando lo stato \"Da leggere\".")
        } actions: {
            Button("Aggiungi un libro", action: onAddBook)
                .buttonStyle(.borderedProminent)
                .tint(.pbGreen)
        }
    }

    // MARK: Griglia

    private var searchHeader: some View {
        SearchField(text: $searchText, prompt: "Cerca nella watchlist")
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
    }

    private var noResults: some View {
        ContentUnavailableView.search(text: searchText)
            .padding(.top, 24)
    }

    private var gridContent: some View {
        ScrollView {
            searchHeader

            if visibleBooks.isEmpty {
                noResults
            }

            LazyVGrid(columns: gridColumns, spacing: 18) {
                ForEach(visibleBooks) { book in
                    VStack(spacing: 8) {
                        NavigationLink(value: book) {
                            BookCardView(book: book, showsMeta: false)
                        }
                        .buttonStyle(.plain)

                        Button {
                            markAsRead(book)
                        } label: {
                            Label("Letto", systemImage: "checkmark")
                                .font(.caption.weight(.bold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(.pbGreen)
                        .accessibilityLabel("Segna \(book.title) come letto")
                    }
                    .contextMenu { contextMenu(for: book) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.immediately)
    }

    // MARK: Lista

    private var listContent: some View {
        List {
            Section {
                searchHeader
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            .listSectionSpacing(0)

            if visibleBooks.isEmpty {
                noResults
                    .listRowBackground(Color.clear)
            }

            ForEach(visibleBooks) { book in
                HStack(spacing: 8) {
                    NavigationLink(value: book) {
                        BookRowView(book: book, showsRating: false)
                    }
                    Button {
                        markAsRead(book)
                    } label: {
                        Image(systemName: "checkmark.circle")
                            .font(.title2)
                            .foregroundStyle(Color.pbGreen)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Segna \(book.title) come letto")
                }
                .listRowBackground(Color.pbSurface)
                .swipeActions(edge: .leading) {
                    Button {
                        startReading(book)
                    } label: {
                        Label("Inizia", systemImage: "book")
                    }
                    .tint(.pbBlue)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        bookPendingDeletion = book
                    } label: {
                        Label("Elimina", systemImage: "trash")
                    }
                    Button {
                        markAsRead(book)
                    } label: {
                        Label("Letto", systemImage: "checkmark")
                    }
                    .tint(.pbGreen)
                }
                .contextMenu { contextMenu(for: book) }
            }
        }
        .listStyle(.insetGrouped)
        .pbFormStyle()
    }

    @ViewBuilder
    private func contextMenu(for book: BookItem) -> some View {
        Button {
            markAsRead(book)
        } label: {
            Label("Segna come letto", systemImage: "checkmark.circle")
        }
        Button {
            startReading(book)
        } label: {
            Label("Inizia a leggere", systemImage: "book")
        }
        Button(role: .destructive) {
            bookPendingDeletion = book
        } label: {
            Label("Elimina", systemImage: "trash")
        }
    }

    // MARK: Azioni

    private func markAsRead(_ book: BookItem) {
        Haptics.impact(.light)
        bookToMarkAsRead = book
    }

    private func startReading(_ book: BookItem) {
        book.status = .reading
        Haptics.impact(.medium)
        modelContext.saveLogging()
    }
}
