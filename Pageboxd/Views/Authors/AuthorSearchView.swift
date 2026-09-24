import SwiftData
import SwiftUI

/// Ricerca di un autore: prima tra quelli della tua libreria, poi online (Open Library).
@MainActor
struct AuthorSearchView: View {
    @Query private var allBooks: [BookItem]
    @Query private var profiles: [AuthorProfile]

    @State private var query: String
    @State private var results: [AuthorSearchResult] = []
    @State private var isLoading = false
    @State private var errorMessage: String? = nil

    private let startsEmpty: Bool

    init(initialQuery: String = "") {
        _query = State(initialValue: initialQuery)
        startsEmpty = initialQuery.isEmpty
    }

    private var photoPaths: [String: String] {
        Dictionary(profiles.compactMap { profile in profile.photoPath.map { (profile.key, $0) } }, uniquingKeysWith: { first, _ in first })
    }

    private var localMatches: [LibraryAuthor] {
        let trimmed = query.trimmed
        guard !trimmed.isEmpty else { return [] }
        let queryTokens = TextMatching.tokens(trimmed)
        return LibraryAuthor.collect(from: allBooks).filter { author in
            let nameTokens = TextMatching.tokens(author.name)
            return queryTokens.allSatisfy { token in nameTokens.contains { $0.hasPrefix(token) } }
        }
    }

    var body: some View {
        List {
            if !localMatches.isEmpty {
                Section("Nella tua libreria") {
                    ForEach(localMatches) { author in
                        NavigationLink(value: AuthorRoute(name: author.name)) {
                            LibraryAuthorRow(author: author, photoPath: photoPaths[author.key])
                        }
                        .listRowBackground(Color.pbSurface)
                    }
                }
            }

            onlineSection
        }
        .listStyle(.insetGrouped)
        .pbFormStyle()
        .safeAreaInset(edge: .top) {
            SearchField(text: $query, prompt: "Nome dell'autore", autofocus: startsEmpty)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.pbBackground)
        }
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle("Autori")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await search(query)
        }
    }

    @ViewBuilder
    private var onlineSection: some View {
        let trimmed = query.trimmed
        if trimmed.count < 2 {
            Section {
                Label("Scrivi il nome di un autore per vedere foto, biografia e bibliografia.", systemImage: "person.crop.circle.badge.questionmark")
                    .font(.subheadline)
                    .foregroundStyle(Color.pbTextSecondary)
                    .listRowBackground(Color.clear)
            }
        } else {
            Section {
                if isLoading && results.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                } else if let errorMessage, results.isEmpty {
                    Label(errorMessage, systemImage: "wifi.exclamationmark")
                        .font(.subheadline)
                        .foregroundStyle(Color.pbTextSecondary)
                        .listRowBackground(Color.clear)
                } else if results.isEmpty {
                    Text("Nessun autore trovato online.")
                        .font(.subheadline)
                        .foregroundStyle(Color.pbTextSecondary)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(results) { result in
                        NavigationLink(value: result.route) {
                            onlineRow(result)
                        }
                        .listRowBackground(Color.pbSurface)
                    }
                }
            } header: {
                HStack {
                    Text("Online")
                    if isLoading && !results.isEmpty {
                        ProgressView().controlSize(.mini)
                    }
                }
            }
        }
    }

    private func onlineRow(_ result: AuthorSearchResult) -> some View {
        HStack(spacing: 14) {
            AuthorAvatarView(name: result.name, remoteURL: result.photoURL, size: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(result.name)
                    .font(.headline)
                Text(details(for: result))
                    .font(.subheadline)
                    .foregroundStyle(Color.pbTextSecondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    private func details(for result: AuthorSearchResult) -> String {
        var parts: [String] = []
        if let year = result.birthDate.flatMap({ MetadataParsing.year(from: $0) }) {
            parts.append("n. \(year)")
        }
        if let work = result.topWork?.nilIfBlank {
            parts.append(work)
        }
        if let count = result.workCount, count > 0 {
            parts.append(count == 1 ? "1 opera" : "\(count) opere")
        }
        return parts.joined(separator: " · ")
    }

    private func search(_ text: String) async {
        let trimmed = text.trimmed
        guard trimmed.count >= 2 else {
            results = []
            errorMessage = nil
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let found = try await AuthorService.shared.searchAuthors(trimmed)
            guard !Task.isCancelled else { return }
            results = found
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
