import SwiftData
import SwiftUI

@MainActor
struct LibraryView: View {
    var onAddBook: () -> Void

    @Environment(\.modelContext) private var modelContext

    @Query(
        filter: #Predicate<BookItem> { $0.statusRaw != "watchlist" },
        sort: \BookItem.dateAdded,
        order: .reverse
    )
    private var books: [BookItem]

    @Query(sort: \ReadingLog.date, order: .reverse)
    private var logs: [ReadingLog]

    /// Tutti i libri, watchlist compresa: servono per la vista Autori.
    @Query private var allBooks: [BookItem]
    @Query private var authorProfiles: [AuthorProfile]

    @AppStorage(AppStorageKeys.libraryLayout) private var layoutRaw = LibraryLayout.grid.rawValue
    @AppStorage(AppStorageKeys.librarySort) private var sortRaw = LibrarySort.readDate.rawValue

    @State private var languageFilter: LanguageFilter = .all
    @State private var ratingFilter: RatingFilter = .any
    @State private var likedOnly = false
    @State private var searchText = ""
    @State private var bookPendingDeletion: BookItem? = nil

    private let gridColumns = Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: 3)

    private var layout: LibraryLayout { LibraryLayout(rawValue: layoutRaw) ?? .grid }
    private var sort: LibrarySort { LibrarySort(rawValue: sortRaw) ?? .readDate }

    private var hasActiveFilters: Bool {
        languageFilter != .all || ratingFilter != .any || likedOnly || !searchText.trimmed.isEmpty
    }

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.pbBackground)
                .navigationTitle("Libreria")
                .navigationBarTitleDisplayMode(.inline)
                .pageboxdDestinations()
                .confirmationDialog(
                    "Eliminare questo libro?",
                    isPresented: Binding(isPresent: $bookPendingDeletion),
                    titleVisibility: .visible,
                    presenting: bookPendingDeletion
                ) { book in
                    Button("Elimina", role: .destructive) {
                        Haptics.warning()
                        book.deleteWithAssets(from: modelContext)
                    }
                } message: { book in
                    Text("\"\(book.title)\", le sue letture e la foto della tua edizione verranno rimossi definitivamente.")
                }
        }
    }

    // MARK: Header con toggle e filtri

    private var header: some View {
        VStack(spacing: 10) {
            SearchField(
                text: $searchText,
                prompt: layout == .authors ? "Cerca un autore" : "Cerca titolo o autore"
            )

            Picker("Vista", selection: $layoutRaw) {
                ForEach(LibraryLayout.allCases) { option in
                    Text(option.title).tag(option.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: layoutRaw) { Haptics.selection() }

            if layout != .authors {
                filterChips
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(LanguageFilter.allCases) { filter in
                    Button {
                        languageFilter = filter
                        Haptics.selection()
                    } label: {
                        FilterChip(title: filter.title, isSelected: languageFilter == filter)
                    }
                    .buttonStyle(.plain)
                }

                Divider().frame(height: 22)

                Menu {
                    Picker("Valutazione", selection: $ratingFilter) {
                        ForEach(RatingFilter.allCases) { filter in
                            Text(filter.title).tag(filter)
                        }
                    }
                } label: {
                    FilterChip(title: ratingFilter.chipTitle, systemImage: "star.fill", isSelected: ratingFilter != .any)
                }

                Button {
                    likedOnly.toggle()
                    Haptics.impact(.light)
                } label: {
                    FilterChip(title: "Preferiti", systemImage: likedOnly ? "heart.fill" : "heart", isSelected: likedOnly)
                }
                .buttonStyle(.plain)

                Menu {
                    Picker("Ordina per", selection: $sortRaw) {
                        ForEach(LibrarySort.allCases) { option in
                            Label(option.title, systemImage: option.systemImage).tag(option.rawValue)
                        }
                    }
                } label: {
                    FilterChip(title: sort.title, systemImage: "arrow.up.arrow.down", isSelected: false)
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.horizontal, -16)
    }

    // MARK: Contenuto

    @ViewBuilder
    private var content: some View {
        if books.isEmpty {
            emptyLibrary
        } else {
            switch layout {
            case .grid: gridContent
            case .diary: diaryContent
            case .authors: authorsContent
            }
        }
    }

    private var emptyLibrary: some View {
        ContentUnavailableView {
            Label("La tua libreria è vuota", systemImage: "books.vertical")
        } description: {
            Text("Scansiona il codice a barre di un libro, cercalo online o aggiungilo a mano.")
        } actions: {
            Button("Aggiungi un libro", action: onAddBook)
                .buttonStyle(.borderedProminent)
                .tint(.pbGreen)

            BackupConnectButton {
                Label("Ripristina da backup", systemImage: "arrow.counterclockwise.icloud")
            }
            .buttonStyle(.bordered)
        }
        .frame(maxHeight: .infinity)
    }

    private var noResults: some View {
        ContentUnavailableView {
            Label("Nessun risultato", systemImage: "line.3.horizontal.decrease.circle")
        } description: {
            Text("Nessun libro corrisponde ai filtri selezionati.")
        } actions: {
            Button("Azzera filtri", action: resetFilters)
                .buttonStyle(.bordered)
        }
        .padding(.top, 40)
    }

    // MARK: Griglia copertine

    @ViewBuilder
    private var gridContent: some View {
        let filtered = filteredBooks
        ScrollView {
            header

            if filtered.isEmpty {
                noResults
            } else {
                LazyVGrid(columns: gridColumns, spacing: 16) {
                    ForEach(filtered) { book in
                        NavigationLink(value: book) {
                            BookCardView(book: book)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { contextMenu(for: book) }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)

                Text(countLabel(filtered.count))
                    .font(.footnote)
                    .foregroundStyle(Color.pbTextSecondary)
                    .padding(.bottom, 24)
            }
        }
        .scrollDismissesKeyboard(.immediately)
    }

    @ViewBuilder
    private func contextMenu(for book: BookItem) -> some View {
        Button {
            book.liked.toggle()
            Haptics.impact(.medium)
            modelContext.saveLogging()
        } label: {
            Label(book.liked ? "Rimuovi Mi piace" : "Mi piace", systemImage: book.liked ? "heart.slash" : "heart")
        }
        Button(role: .destructive) {
            bookPendingDeletion = book
        } label: {
            Label("Elimina", systemImage: "trash")
        }
    }

    // MARK: Diario cronologico

    @ViewBuilder
    private var diaryContent: some View {
        let sections = diarySections
        List {
            Section {
                header
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            .listSectionSpacing(0)

            if sections.allSatisfy({ $0.entries.isEmpty }) {
                Section {
                    Group {
                        if hasActiveFilters {
                            noResults
                        } else {
                            ContentUnavailableView {
                                Label("Diario vuoto", systemImage: "calendar")
                            } description: {
                                Text("Le letture completate compariranno qui in ordine cronologico.")
                            }
                            .padding(.top, 40)
                        }
                    }
                    .listRowBackground(Color.clear)
                }
            } else {
                ForEach(sections) { section in
                    Section {
                        ForEach(section.entries) { entry in
                            NavigationLink(value: entry.book) {
                                DiaryEntryRow(entry: entry)
                            }
                            .listRowBackground(Color.pbSurface)
                            .swipeActions(edge: .leading) {
                                Button {
                                    entry.book.liked.toggle()
                                    Haptics.impact(.medium)
                                    modelContext.saveLogging()
                                } label: {
                                    Label("Mi piace", systemImage: entry.book.liked ? "heart.slash.fill" : "heart.fill")
                                }
                                .tint(.pbOrange)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    Haptics.warning()
                                    entry.book.removeReading(on: entry.date, in: modelContext)
                                } label: {
                                    Label("Rimuovi lettura", systemImage: "calendar.badge.minus")
                                }
                            }
                        }
                    } header: {
                        if let title = section.title {
                            Text(title)
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(Color.pbTextSecondary)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .pbFormStyle()
        .scrollDismissesKeyboard(.immediately)
    }

    // MARK: Autori

    private var authorsContent: some View {
        let query = searchText.trimmed
        let queryTokens = TextMatching.tokens(query)
        let authors = LibraryAuthor.collect(from: allBooks).filter { author in
            guard !queryTokens.isEmpty else { return true }
            let nameTokens = TextMatching.tokens(author.name)
            return queryTokens.allSatisfy { token in nameTokens.contains { $0.hasPrefix(token) } }
        }
        let photos = Dictionary(
            authorProfiles.compactMap { profile in profile.photoPath.map { (profile.key, $0) } },
            uniquingKeysWith: { first, _ in first }
        )

        return List {
            Section {
                header
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            .listSectionSpacing(0)

            if authors.isEmpty {
                Section {
                    Text(query.isEmpty ? "Nessun autore in libreria." : "Nessun autore della tua libreria corrisponde.")
                        .font(.subheadline)
                        .foregroundStyle(Color.pbTextSecondary)
                        .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(authors) { author in
                        NavigationLink(value: AuthorRoute(name: author.name)) {
                            LibraryAuthorRow(author: author, photoPath: photos[author.key])
                        }
                        .listRowBackground(Color.pbSurface)
                    }
                } header: {
                    Text(authors.count == 1 ? "1 autore" : "\(authors.count) autori")
                }
            }

            Section {
                NavigationLink(value: AuthorSearchRoute(query: query)) {
                    Label(
                        query.isEmpty ? "Cerca un autore online" : "Cerca «\(query)» online",
                        systemImage: "globe"
                    )
                    .foregroundStyle(Color.pbGreen)
                }
                .listRowBackground(Color.pbSurface)
            } footer: {
                Text("Foto, biografia e bibliografia completa da Wikipedia e Open Library.")
            }
        }
        .listStyle(.insetGrouped)
        .pbFormStyle()
        .scrollDismissesKeyboard(.immediately)
    }

    // MARK: Dati filtrati

    private var filteredBooks: [BookItem] {
        let currentSort = sort
        return books
            .filter { matchesFilters($0) }
            .sorted { currentSort.areInIncreasingOrder($0, $1) }
    }

    private var diarySections: [DiarySection] {
        let entries = logs.compactMap { log -> DiaryEntry? in
            guard let book = log.book, book.status != .watchlist, matchesFilters(book) else { return nil }
            return DiaryEntry(id: log.id, date: log.date, isReread: log.isReread, book: book)
        }

        switch sort {
        case .readDate, .dateAdded:
            let calendar = Calendar.current
            let grouped = Dictionary(grouping: entries) { entry in
                calendar.dateInterval(of: .month, for: entry.date)?.start ?? entry.date
            }
            return grouped.keys.sorted(by: >).map { month in
                DiarySection(
                    id: month.timeIntervalSince1970.description,
                    title: month.formatted(.dateTime.month(.wide).year().locale(.pageboxd)).capitalized(with: .pageboxd),
                    entries: grouped[month, default: []].sorted { $0.date > $1.date }
                )
            }
        case .title, .rating:
            let sorted = entries.sorted { lhs, rhs in
                if sort.areInIncreasingOrder(lhs.book, rhs.book) { return true }
                if sort.areInIncreasingOrder(rhs.book, lhs.book) { return false }
                return lhs.date > rhs.date
            }
            return [DiarySection(id: "all", title: nil, entries: sorted)]
        }
    }

    private func matchesFilters(_ book: BookItem) -> Bool {
        guard languageFilter.matches(book.language),
              ratingFilter.matches(book.rating),
              !likedOnly || book.liked
        else { return false }

        let query = searchText.trimmed
        guard !query.isEmpty else { return true }
        return book.title.localizedCaseInsensitiveContains(query)
            || book.author.localizedCaseInsensitiveContains(query)
            || (book.isbn?.contains(query) ?? false)
    }

    private func resetFilters() {
        languageFilter = .all
        ratingFilter = .any
        likedOnly = false
        searchText = ""
        Haptics.selection()
    }

    private func countLabel(_ count: Int) -> String {
        count == 1 ? "1 libro" : "\(count) libri"
    }
}

// MARK: - Modelli del diario

struct DiaryEntry: Identifiable {
    let id: UUID
    let date: Date
    let isReread: Bool
    let book: BookItem
}

struct DiarySection: Identifiable {
    let id: String
    let title: String?
    let entries: [DiaryEntry]
}

// MARK: - Riga del diario

struct DiaryEntryRow: View {
    let entry: DiaryEntry

    var body: some View {
        HStack(spacing: 14) {
            VStack(spacing: 0) {
                Text(entry.date.formatted(.dateTime.day().locale(.pageboxd)))
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text(entry.date.formatted(.dateTime.month(.abbreviated).locale(.pageboxd)).uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.pbTextSecondary)
            }
            .frame(width: 40)

            BookCoverView(
                path: entry.book.coverPath,
                title: entry.book.title,
                author: entry.book.author,
                cornerRadius: 4,
                maxPixelSize: 240
            )
            .frame(width: 44)

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.book.title)
                    .font(.headline)
                    .lineLimit(2)
                Text(entry.book.author)
                    .font(.subheadline)
                    .foregroundStyle(Color.pbTextSecondary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if entry.book.isRated {
                        RatingStarsDisplay(rating: entry.book.rating, size: 11)
                    }
                    if entry.book.liked {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.pbOrange)
                    }
                    if entry.isReread {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.pbBlue)
                            .accessibilityLabel("Rilettura")
                    }
                    Text(entry.book.languageShortCode)
                        .font(.system(size: 9, weight: .heavy))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .foregroundStyle(entry.book.language.tint)
                        .background(entry.book.language.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Ordinamento

extension LibrarySort {
    func areInIncreasingOrder(_ lhs: BookItem, _ rhs: BookItem) -> Bool {
        switch self {
        case .readDate:
            let left = sortDate(for: lhs)
            let right = sortDate(for: rhs)
            if left != right { return left > right }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        case .title:
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        case .rating:
            if lhs.rating != rhs.rating { return lhs.rating > rhs.rating }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        case .dateAdded:
            return lhs.dateAdded > rhs.dateAdded
        }
    }

    /// I libri in lettura compaiono per primi, poi quelli letti dal più recente.
    private func sortDate(for book: BookItem) -> Date {
        if book.status == .reading { return .distantFuture }
        return book.lastReadDate ?? book.dateAdded
    }
}
