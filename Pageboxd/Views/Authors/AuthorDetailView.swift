import OSLog
import SwiftData
import SwiftUI

/// Scheda autore: foto, biografia, i suoi libri nella tua libreria e la bibliografia completa.
@MainActor
struct AuthorDetailView: View {
    let route: AuthorRoute

    @Environment(\.modelContext) private var modelContext
    @Query private var allBooks: [BookItem]
    @Query private var profiles: [AuthorProfile]

    @State private var works: [BookMetadata] = []
    @State private var isLoadingProfile = false
    @State private var isLoadingWorks = false
    @State private var profileError: String? = nil
    @State private var isBioExpanded = false
    @State private var workToAdd: BookMetadata? = nil
    @State private var addRequest: AddRequest? = nil
    @State private var isPreparingAdd = false

    struct AddRequest: Identifiable {
        let id = UUID()
        let draft: BookDraft
    }

    private let gridColumns = Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 3)

    init(route: AuthorRoute) {
        self.route = route
        let key = route.key
        _profiles = Query(filter: #Predicate<AuthorProfile> { $0.key == key })
    }

    private var profile: AuthorProfile? { profiles.first }
    private var displayName: String { profile?.name ?? route.name }

    /// Libri della tua libreria scritti (anche) da questo autore.
    private var libraryBooks: [BookItem] {
        allBooks
            .filter { book in book.authorList.contains { TextMatching.authorKey($0) == route.key } }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private var libraryTitleKeys: [String: BookItem] {
        Dictionary(libraryBooks.map { (TextMatching.titleKey($0.title), $0) }, uniquingKeysWith: { first, _ in first })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                if !libraryBooks.isEmpty {
                    statsRow
                }
                bioSection
                librarySection
                bibliographySection
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .background(Color.pbBackground)
        .navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task {
                        await loadProfile(force: true)
                        await loadWorks(force: true)
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoadingProfile || isLoadingWorks)
                .accessibilityLabel("Aggiorna scheda autore")
            }
        }
        .task { await loadProfile(force: false) }
        .task { await loadWorks(force: false) }
        .confirmationDialog(
            workToAdd.map { "Aggiungi «\($0.title)»" } ?? "",
            isPresented: Binding(isPresent: $workToAdd),
            titleVisibility: .visible,
            presenting: workToAdd
        ) { work in
            Button("Da leggere") { prepareAdd(work, status: .watchlist) }
            Button("Già letto") { prepareAdd(work, status: .read) }
            Button("Lo sto leggendo") { prepareAdd(work, status: .reading) }
            Button("Annulla", role: .cancel) {}
        }
        .sheet(item: $addRequest) { request in
            AddEditBookView(
                mode: .create(request.draft),
                notice: "Dati dal catalogo online: se hai un'edizione precisa, scansiona o inserisci il suo ISBN."
            )
        }
        .overlay {
            if isPreparingAdd {
                ProgressView("Recupero i dati…")
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }

    // MARK: Intestazione

    private var header: some View {
        VStack(spacing: 12) {
            AuthorAvatarView(name: displayName, photoPath: profile?.photoPath, size: 120)
                .shadow(color: .black.opacity(0.25), radius: 10, y: 5)
                .overlay(alignment: .bottomTrailing) {
                    if isLoadingProfile {
                        ProgressView()
                            .padding(6)
                            .background(.regularMaterial, in: Circle())
                    }
                }

            Text(displayName)
                .font(.system(.title, design: .serif).weight(.bold))
                .multilineTextAlignment(.center)

            if let summary = profile?.summary {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(Color.pbTextSecondary)
                    .multilineTextAlignment(.center)
            }
            if let lifeSpan = profile?.lifeSpan {
                Text(lifeSpan)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.pbTextSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 16)
    }

    private var statsRow: some View {
        let books = libraryBooks
        let read = books.filter { $0.status == .read }
        let rated = read.filter(\.isRated)
        let average = rated.isEmpty ? nil : rated.reduce(0) { $0 + $1.rating } / Double(rated.count)

        return HStack(spacing: 0) {
            statItem(value: "\(books.count)", label: books.count == 1 ? "libro" : "libri")
            Divider().frame(height: 32)
            statItem(value: "\(read.count)", label: read.count == 1 ? "letto" : "letti")
            Divider().frame(height: 32)
            statItem(
                value: average.map { $0.formatted(.number.precision(.fractionLength(1)).locale(.pageboxd)) + "★" } ?? "—",
                label: "voto medio"
            )
            Divider().frame(height: 32)
            statItem(value: "\(books.filter(\.liked).count)", label: "preferiti")
        }
        .pbCard(padding: 12)
    }

    private func statItem(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.headline)
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(Color.pbTextSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Biografia

    @ViewBuilder
    private var bioSection: some View {
        if let bio = profile?.bio {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "Biografia", systemImage: "person.text.rectangle")
                Text(bio)
                    .font(.body)
                    .lineSpacing(3)
                    .lineLimit(isBioExpanded ? nil : 6)
                    .textSelection(.enabled)
                HStack {
                    Button(isBioExpanded ? "Mostra meno" : "Mostra tutto") {
                        withAnimation(.easeInOut(duration: 0.2)) { isBioExpanded.toggle() }
                    }
                    .font(.subheadline.weight(.semibold))
                    .tint(.pbGreen)
                    Spacer()
                    if let source = profile?.bioSource {
                        if let url = profile?.sourceURL {
                            Link("Fonte: \(source)", destination: url)
                                .font(.caption)
                                .tint(Color.pbTextSecondary)
                        } else {
                            Text("Fonte: \(source)")
                                .font(.caption)
                                .foregroundStyle(Color.pbTextSecondary)
                        }
                    }
                }
            }
        } else if let profileError, profile == nil {
            Label(profileError, systemImage: "wifi.exclamationmark")
                .font(.subheadline)
                .foregroundStyle(Color.pbTextSecondary)
                .pbCard()
        }
    }

    // MARK: Nella tua libreria

    @ViewBuilder
    private var librarySection: some View {
        if !libraryBooks.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "Nella tua libreria", systemImage: "books.vertical")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(libraryBooks) { book in
                            NavigationLink(value: book) {
                                BookCardView(book: book)
                                    .frame(width: 100)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.horizontal, -16)
            }
        }
    }

    // MARK: Bibliografia

    private var bibliographySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionTitle(title: "Bibliografia", systemImage: "text.book.closed")
                Spacer()
                if isLoadingWorks {
                    ProgressView()
                }
            }

            if works.isEmpty && !isLoadingWorks {
                Text("Nessuna opera trovata nei cataloghi online.")
                    .font(.subheadline)
                    .foregroundStyle(Color.pbTextSecondary)
            } else {
                LazyVGrid(columns: gridColumns, spacing: 16) {
                    ForEach(works) { work in
                        workCell(work)
                    }
                }
            }
            Text("Tocca un'opera per aggiungerla alla tua libreria.")
                .font(.caption)
                .foregroundStyle(Color.pbTextSecondary)
        }
    }

    @ViewBuilder
    private func workCell(_ work: BookMetadata) -> some View {
        if let owned = libraryTitleKeys[TextMatching.titleKey(work.title)] {
            NavigationLink(value: owned) {
                WorkCardView(work: work, isInLibrary: true)
            }
            .buttonStyle(.plain)
        } else {
            Button {
                Haptics.impact(.light)
                workToAdd = work
            } label: {
                WorkCardView(work: work, isInLibrary: false)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Caricamento

    private func loadProfile(force: Bool) async {
        if let profile, !force, !profile.isStale { return }
        isLoadingProfile = true
        defer { isLoadingProfile = false }

        do {
            let details = try await AuthorService.shared.details(
                for: displayName,
                openLibraryKey: route.openLibraryKey ?? profile?.openLibraryKey
            )

            var newPhotoPath: String?
            if let url = details.photoURL,
               let image = try? await AuthorService.shared.downloadPhoto(from: url) {
                newPhotoPath = try? await ImageStorageManager.shared.save(image, directory: ImageStorageManager.authorsDirectoryName)
            }

            let target: AuthorProfile
            if let profile {
                target = profile
            } else {
                target = AuthorProfile(key: route.key, name: route.name)
                modelContext.insert(target)
            }
            target.summary = details.summary ?? target.summary
            target.bio = details.bio ?? target.bio
            target.bioSource = details.bio != nil ? details.bioSource : target.bioSource
            target.sourceURLString = details.sourceURL?.absoluteString ?? target.sourceURLString
            target.birthDate = details.birthDate ?? target.birthDate
            target.deathDate = details.deathDate ?? target.deathDate
            target.openLibraryKey = details.openLibraryKey ?? target.openLibraryKey
            var obsoletePhoto: String?
            if let newPhotoPath {
                obsoletePhoto = target.photoPath
                target.photoPath = newPhotoPath
            }
            target.fetchedAt = Date()

            try modelContext.save()
            ImageStorageManager.shared.deleteImage(relativePath: obsoletePhoto)
            profileError = nil
        } catch is CancellationError {
            return
        } catch {
            profileError = "Informazioni sull'autore non disponibili al momento. Riprova con la connessione attiva."
            Logger.pageboxd.info("Scheda autore non caricata: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadWorks(force: Bool) async {
        guard force || works.isEmpty else { return }
        isLoadingWorks = true
        defer { isLoadingWorks = false }
        let loaded = await AuthorService.shared.works(
            for: displayName,
            openLibraryKey: route.openLibraryKey ?? profile?.openLibraryKey
        )
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            works = loaded
        }
    }

    private func prepareAdd(_ work: BookMetadata, status: ReadingStatus) {
        isPreparingAdd = true
        Task {
            let enriched = await BookMetadataFetcher.shared.enrich(work)
            var draft = BookDraft(metadata: enriched)
            draft.status = status
            if draft.authorNames.isEmpty {
                draft.authors = [AuthorEntry(name: displayName)]
            }
            isPreparingAdd = false
            addRequest = AddRequest(draft: draft)
        }
    }
}

// MARK: - Card opera

struct WorkCardView: View {
    let work: BookMetadata
    let isInLibrary: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Color.pbSurfaceElevated
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .overlay {
                    AsyncImage(url: work.listThumbnailURL) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            CoverPlaceholderView(title: work.title, author: work.authorLine)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if isInLibrary {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(Color.pbGreen, Color.pbBackground)
                            .padding(4)
                    }
                }
                .shadow(color: .black.opacity(0.2), radius: 3, y: 2)

            Text(work.title)
                .font(.caption.weight(.semibold))
                .lineLimit(2)
            HStack(spacing: 4) {
                if let year = work.publicationYear {
                    Text(String(year))
                }
                if let language = work.languageCode, language != "en" {
                    Text(language.uppercased())
                        .font(.system(size: 8, weight: .heavy))
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(Color.pbSurfaceElevated, in: RoundedRectangle(cornerRadius: 3))
                }
            }
            .font(.caption2)
            .foregroundStyle(Color.pbTextSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(isInLibrary ? "Già nella tua libreria" : "Aggiungi alla libreria")
    }
}
