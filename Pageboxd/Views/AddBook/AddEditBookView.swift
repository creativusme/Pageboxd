import OSLog
import PhotosUI
import SwiftData
import SwiftUI

// MARK: - Bozza modificabile

struct ReadDateEntry: Identifiable, Equatable {
    let id: UUID
    var date: Date

    init(id: UUID = UUID(), date: Date) {
        self.id = id
        self.date = date
    }
}

struct AuthorEntry: Identifiable, Equatable {
    let id: UUID
    var name: String

    init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

/// Copia dei dati del form: il modello SwiftData viene toccato solo al salvataggio.
struct BookDraft: Equatable {
    var title = ""
    var authors: [AuthorEntry] = [AuthorEntry(name: "")]
    var isbn = ""
    var yearText = ""
    var pagesText = ""
    var synopsis = ""
    var language: ReadingLanguage = .italian
    var otherLanguageCode: String?
    var status: ReadingStatus = .read
    var rating: Double = 0
    var liked = false
    var review = ""
    var readEntries: [ReadDateEntry] = [ReadDateEntry(date: Date())]
    var timesRead = 1
    var remoteCoverURL: URL?

    init() {}

    init(isbn: String) {
        self.isbn = isbn
    }

    init(metadata: BookMetadata) {
        title = metadata.title
        authors = metadata.authors.isEmpty ? [AuthorEntry(name: "")] : metadata.authors.map { AuthorEntry(name: $0) }
        isbn = metadata.isbn ?? ""
        yearText = metadata.publicationYear.map { String($0) } ?? ""
        pagesText = metadata.pageCount.map { String($0) } ?? ""
        synopsis = metadata.synopsis ?? ""
        language = ReadingLanguage.from(isoCode: metadata.languageCode) ?? .italian
        otherLanguageCode = language == .other ? LanguageCatalog.normalizedCode(metadata.languageCode) : nil
        remoteCoverURL = metadata.coverURL
    }

    init(book: BookItem) {
        title = book.title
        authors = book.authorList.isEmpty ? [AuthorEntry(name: "")] : book.authorList.map { AuthorEntry(name: $0) }
        isbn = book.isbn ?? ""
        yearText = book.publicationYear.map { String($0) } ?? ""
        pagesText = book.pageCount.map { String($0) } ?? ""
        synopsis = book.synopsis ?? ""
        language = book.language
        otherLanguageCode = book.otherLanguageCode
        status = book.status
        rating = book.rating
        liked = book.liked
        review = book.review
        readEntries = book.readDates.sorted(by: >).map { ReadDateEntry(date: $0) }
        timesRead = max(book.timesRead, book.readDates.count, 1)
    }

    /// Riempie solo i campi vuoti con i dati del catalogo, senza sovrascrivere quanto scritto dall'utente.
    mutating func fillEmptyFields(from metadata: BookMetadata) {
        if title.trimmed.isEmpty { title = metadata.title }
        if authorNames.isEmpty, !metadata.authors.isEmpty {
            authors = metadata.authors.map { AuthorEntry(name: $0) }
        }
        if let isbn = metadata.isbn { self.isbn = isbn }
        if yearText.trimmed.isEmpty, let year = metadata.publicationYear { yearText = String(year) }
        if pagesText.trimmed.isEmpty, let pages = metadata.pageCount { pagesText = String(pages) }
        if synopsis.trimmed.isEmpty, let text = metadata.synopsis { synopsis = text }
        if remoteCoverURL == nil { remoteCoverURL = metadata.coverURL }
    }

    var authorNames: [String] { authors.compactMap { $0.name.nilIfBlank } }
    var authorLine: String { authorNames.joined(separator: ", ") }

    var parsedYear: Int? {
        guard let year = Int(yearText.trimmed) else { return nil }
        let maxYear = Calendar.current.component(.year, from: Date()) + 1
        return (1...maxYear).contains(year) ? year : nil
    }

    var parsedPages: Int? {
        guard let pages = Int(pagesText.trimmed), pages > 0, pages < 100_000 else { return nil }
        return pages
    }

    var normalizedISBN: String? {
        let raw = isbn.trimmed
        guard !raw.isEmpty else { return nil }
        return ISBN.normalize(raw) ?? ISBN.cleanedCharacters(raw).nilIfBlank
    }

    var isISBNValid: Bool {
        isbn.trimmed.isEmpty || ISBN.normalize(isbn) != nil
    }
}

// MARK: - Form di creazione / modifica

@MainActor
struct AddEditBookView: View {
    enum Mode {
        case create(BookDraft)
        case edit(BookItem)
        case markAsRead(BookItem)
    }

    struct CropSource: Identifiable {
        let id = UUID()
        let image: UIImage
        var suggestedQuad: BookQuad? = nil
    }

    /// Lato lungo dell'immagine di lavoro per il ritaglio: più definita di quella salvata (1080 px).
    private static let cropWorkingDimension: CGFloat = 2048

    private enum Field: Hashable {
        case title
        case author(UUID)
        case isbn
        case year
        case pages
        case synopsis
        case review
    }

    let mode: Mode
    var notice: String?
    var onSaved: ((BookItem) -> Void)?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var draft: BookDraft
    @State private var initialDraft: BookDraft
    @State private var pickedImage: UIImage? = nil
    @State private var removesExistingPhoto = false
    @State private var remoteCoverImage: UIImage? = nil
    @State private var isLoadingRemoteCover = false
    @State private var photoPickerItem: PhotosPickerItem? = nil
    @State private var isShowingCamera = false
    @State private var capturedImage: UIImage? = nil
    @State private var capturedQuad: BookQuad? = nil
    @State private var cropSource: CropSource? = nil
    @State private var isProcessingPhoto = false
    @State private var isSaving = false
    @State private var isLookingUpISBN = false
    @State private var errorMessage: String? = nil
    @State private var isConfirmingDiscard = false
    @FocusState private var focusedField: Field?

    init(mode: Mode, notice: String? = nil, onSaved: ((BookItem) -> Void)? = nil) {
        self.mode = mode
        self.notice = notice
        self.onSaved = onSaved

        let draft: BookDraft
        switch mode {
        case .create(let prefilled):
            draft = prefilled
        case .edit(let book):
            draft = BookDraft(book: book)
        case .markAsRead(let book):
            var prepared = BookDraft(book: book)
            prepared.status = .read
            if prepared.readEntries.isEmpty {
                prepared.readEntries = [ReadDateEntry(date: Date())]
            } else if book.status != .read {
                prepared.readEntries.insert(ReadDateEntry(date: Date()), at: 0)
            }
            prepared.timesRead = max(prepared.timesRead, prepared.readEntries.count)
            draft = prepared
        }
        _draft = State(initialValue: draft)
        _initialDraft = State(initialValue: draft)
    }

    // MARK: Stato derivato

    private var existingBook: BookItem? {
        switch mode {
        case .create: return nil
        case .edit(let book), .markAsRead(let book): return book
        }
    }

    private var isMarkAsRead: Bool {
        if case .markAsRead = mode { return true }
        return false
    }

    private var navigationTitle: String {
        switch mode {
        case .create: return "Nuovo libro"
        case .edit: return "Modifica"
        case .markAsRead: return "Segna come letto"
        }
    }

    private var existingPersonalPhotoPath: String? {
        removesExistingPhoto ? nil : existingBook?.photoPath
    }

    private var hasPersonalPhoto: Bool {
        pickedImage != nil || existingPersonalPhotoPath != nil
    }

    private var hasChanges: Bool {
        draft != initialDraft || pickedImage != nil || removesExistingPhoto
    }

    private var canSave: Bool {
        !draft.title.trimmed.isEmpty && !isSaving && !isProcessingPhoto
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                Form {
                    if let notice {
                        Section {
                            Label(notice, systemImage: "info.circle.fill")
                                .font(.subheadline)
                                .foregroundStyle(Color.pbTextSecondary)
                        }
                        .listRowBackground(Color.pbSurface)
                    }

                    photoSection
                    statusSection

                    if isMarkAsRead {
                        judgementSection
                        readingsSection
                        reviewSection
                        detailsSection
                    } else {
                        detailsSection
                        if draft.status != .watchlist {
                            judgementSection
                        } else {
                            languageOnlySection
                        }
                        if draft.status == .read {
                            readingsSection
                        }
                        if draft.status != .watchlist {
                            reviewSection
                        }
                    }
                }
                .pbFormStyle()
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: focusedField) { _, field in
                    guard let field else { return }
                    scrollToField(field, using: proxy)
                }
                .navigationTitle(navigationTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
                .interactiveDismissDisabled(hasChanges || isSaving)
                .disabled(isSaving)
                .overlay {
                    if isSaving {
                        ProgressView("Salvataggio…")
                            .padding(24)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
                .onChange(of: photoPickerItem) { _, newItem in
                    guard let newItem else { return }
                    Task { await loadPickedPhoto(newItem) }
                }
                .onChange(of: draft.status) { _, newStatus in
                    if newStatus == .read && draft.readEntries.isEmpty {
                        draft.readEntries = [ReadDateEntry(date: Date())]
                    }
                    Haptics.selection()
                }
                .onChange(of: draft.readEntries.count) { _, count in
                    draft.timesRead = max(draft.timesRead, count, 1)
                }
                .task(id: draft.remoteCoverURL) { await loadRemoteCover() }
                .fullScreenCover(isPresented: $isShowingCamera, onDismiss: presentCropForCapturedImage) {
                    BookCameraView { image, quad in
                        capturedImage = image
                        capturedQuad = quad
                    }
                }
                .alert("Attenzione", isPresented: Binding(isPresent: $errorMessage)) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(errorMessage ?? "")
                }
                .confirmationDialog("Scartare le modifiche?", isPresented: $isConfirmingDiscard, titleVisibility: .visible) {
                    Button("Scarta modifiche", role: .destructive) { dismiss() }
                    Button("Continua a modificare", role: .cancel) {}
                }
            }
        }
    }

    /// Dopo l'apparizione della tastiera porta il campo al centro dello schermo.
    private func scrollToField(_ field: Field, using proxy: ScrollViewProxy) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            withAnimation(.easeOut(duration: 0.25)) {
                proxy.scrollTo(field, anchor: .center)
            }
        }
    }

    /// Ordine dei campi per le frecce sopra la tastiera.
    private var fieldOrder: [Field] {
        var order: [Field] = [.title]
        order += draft.authors.map { Field.author($0.id) }
        order += [.isbn, .year, .pages, .synopsis]
        if draft.status != .watchlist {
            order.append(.review)
        }
        return order
    }

    private func moveFocus(by offset: Int) {
        guard let current = focusedField, let index = fieldOrder.firstIndex(of: current) else { return }
        let target = index + offset
        guard fieldOrder.indices.contains(target) else { return }
        focusedField = fieldOrder[target]
    }

    // MARK: Sezione foto

    private var photoSection: some View {
        Section {
            VStack(spacing: 14) {
                photoPreview
                    .frame(maxWidth: .infinity)

                HStack(spacing: 10) {
                    Button {
                        openCamera()
                    } label: {
                        Label("Scatta Foto", systemImage: "camera.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.pbGreen)
                    .disabled(!CameraDevices.isAvailable)

                    PhotosPicker(selection: $photoPickerItem, matching: .images) {
                        Label("Galleria", systemImage: "photo.on.rectangle")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.pbGreen)
                }
                .controlSize(.large)

                if hasPersonalPhoto {
                    HStack(spacing: 24) {
                        Button {
                            Task { await cropCurrentPhoto() }
                        } label: {
                            Label("Ritaglia", systemImage: "crop")
                                .font(.subheadline)
                        }
                        .buttonStyle(.borderless)
                        .tint(.pbGreen)

                        Button(role: .destructive) {
                            withAnimation {
                                pickedImage = nil
                                removesExistingPhoto = existingBook?.photoPath != nil
                            }
                            Haptics.impact(.light)
                        } label: {
                            Label("Rimuovi foto", systemImage: "trash")
                                .font(.subheadline)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            .padding(.vertical, 6)
            .fullScreenCover(item: $cropSource) { source in
                PhotoCropView(image: source.image, suggestedQuad: source.suggestedQuad) { cropped in
                    withAnimation {
                        pickedImage = cropped
                        removesExistingPhoto = false
                    }
                }
            }
        } header: {
            Text("La tua edizione")
        } footer: {
            Text("La foto della tua copia ha sempre la priorità sulla copertina del catalogo. Viene ridimensionata e salvata solo su questo iPhone.")
        }
        .listRowBackground(Color.pbSurface)
    }

    @ViewBuilder
    private var photoPreview: some View {
        ZStack {
            if let pickedImage {
                Image(uiImage: pickedImage)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else if let path = existingPersonalPhotoPath {
                StoredImageView(path: path, maxPixelSize: 900) { previewPlaceholder }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else if let remoteCoverImage {
                catalogCover(Image(uiImage: remoteCoverImage))
            } else if let path = existingBook?.remoteCoverPath {
                StoredImageView(path: path, maxPixelSize: 900) { previewPlaceholder }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(alignment: .bottom) { catalogCaption }
            } else {
                previewPlaceholder
                    .overlay {
                        if isLoadingRemoteCover {
                            ProgressView()
                        }
                    }
            }

            if isProcessingPhoto {
                ProgressView()
                    .padding(16)
                    .background(.regularMaterial, in: Circle())
            }
        }
        .frame(height: 260)
        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
        .animation(.easeInOut(duration: 0.2), value: pickedImage)
    }

    private func catalogCover(_ image: Image) -> some View {
        image
            .resizable()
            .scaledToFit()
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .bottom) { catalogCaption }
    }

    private var catalogCaption: some View {
        Text("Copertina dal catalogo")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(8)
    }

    private var previewPlaceholder: some View {
        CoverPlaceholderView(title: draft.title, author: draft.authorLine)
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: Sezioni del form

    private var statusSection: some View {
        Section("Stato") {
            Picker("Stato", selection: $draft.status) {
                ForEach(ReadingStatus.allCases) { status in
                    Text(status.displayName).tag(status)
                }
            }
            .pickerStyle(.segmented)
            .disabled(isMarkAsRead)
        }
        .listRowBackground(Color.pbSurface)
    }

    private var detailsSection: some View {
        Section {
            TextField("Titolo", text: $draft.title)
                .font(.headline)
                .focused($focusedField, equals: .title)
                .submitLabel(.next)
                .onSubmit { moveFocus(by: 1) }
                .id(Field.title)

            ForEach($draft.authors) { $entry in
                HStack {
                    Image(systemName: "person")
                        .foregroundStyle(Color.pbTextSecondary)
                        .frame(width: 20)
                    TextField(entry.id == draft.authors.first?.id ? "Autore" : "Altro autore", text: $entry.name)
                        .textContentType(.name)
                        .focused($focusedField, equals: .author(entry.id))
                        .submitLabel(.next)
                        .onSubmit { moveFocus(by: 1) }
                    if draft.authors.count > 1 {
                        Button {
                            let removedID = entry.id
                            withAnimation { draft.authors.removeAll { $0.id == removedID } }
                            Haptics.impact(.light)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Rimuovi autore")
                    }
                }
                .id(Field.author(entry.id))
            }

            Button {
                let entry = AuthorEntry(name: "")
                withAnimation { draft.authors.append(entry) }
                focusedField = .author(entry.id)
                Haptics.impact(.light)
            } label: {
                Label("Aggiungi un altro autore", systemImage: "person.badge.plus")
                    .font(.subheadline)
            }
            .buttonStyle(.borderless)
            .tint(.pbGreen)

            HStack {
                TextField("ISBN", text: $draft.isbn)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .isbn)
                    .monospacedDigit()

                if isLookingUpISBN {
                    ProgressView()
                } else {
                    Button {
                        Task { await lookupISBN() }
                    } label: {
                        Label("Compila", systemImage: "arrow.down.circle.fill")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                    .tint(.pbGreen)
                    .disabled(ISBN.normalize(draft.isbn) == nil)
                    .accessibilityHint("Compila i campi vuoti con i dati del catalogo online")
                }
            }
            .id(Field.isbn)

            LabeledContent("Anno") {
                TextField("es. 2003", text: $draft.yearText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .focused($focusedField, equals: .year)
            }
            .id(Field.year)

            LabeledContent("Pagine") {
                TextField("es. 379", text: $draft.pagesText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .focused($focusedField, equals: .pages)
            }
            .id(Field.pages)

            TextField("Trama", text: $draft.synopsis, axis: .vertical)
                .lineLimit(3...10)
                .focused($focusedField, equals: .synopsis)
                .id(Field.synopsis)
        } header: {
            Text("Dettagli")
        } footer: {
            if !draft.isISBNValid {
                Text("L'ISBN inserito non sembra valido: verrà salvato così com'è.")
                    .foregroundStyle(Color.pbOrange)
            }
        }
        .listRowBackground(Color.pbSurface)
    }

    private var judgementSection: some View {
        Section("Il tuo giudizio") {
            HStack {
                StarRatingView(rating: $draft.rating, starSize: 32)
                Spacer(minLength: 8)
                LikeButton(isLiked: $draft.liked, size: 28)
            }
            .padding(.vertical, 6)

            languagePicker
        }
        .listRowBackground(Color.pbSurface)
    }

    private var languageOnlySection: some View {
        Section("Lingua di lettura") {
            languagePicker
        }
        .listRowBackground(Color.pbSurface)
    }

    @ViewBuilder
    private var languagePicker: some View {
        Picker("Lingua", selection: $draft.language) {
            ForEach(ReadingLanguage.allCases) { language in
                Text(language.displayName).tag(language)
            }
        }
        .pickerStyle(.segmented)

        if draft.language == .other {
            NavigationLink {
                LanguagePickerView(selection: $draft.otherLanguageCode)
            } label: {
                HStack {
                    Label("Quale lingua?", systemImage: "globe")
                    Spacer()
                    Text(LanguageCatalog.name(for: draft.otherLanguageCode) ?? "Scegli")
                        .foregroundStyle(draft.otherLanguageCode == nil ? Color.pbOrange : Color.pbTextSecondary)
                }
            }
        }
    }

    private var readingsSection: some View {
        Section {
            ForEach($draft.readEntries) { $entry in
                DatePicker(
                    entry.id == draft.readEntries.first?.id ? "Data di lettura" : "Lettura precedente",
                    selection: $entry.date,
                    in: ...Date(),
                    displayedComponents: .date
                )
            }
            .onDelete { offsets in
                draft.readEntries.remove(atOffsets: offsets)
                Haptics.impact(.light)
            }

            Button {
                draft.readEntries.append(ReadDateEntry(date: Date()))
                Haptics.impact(.light)
            } label: {
                Label("Aggiungi un'altra lettura", systemImage: "plus.circle")
            }
            .tint(.pbGreen)

            Stepper(value: $draft.timesRead, in: max(1, draft.readEntries.count)...99) {
                HStack {
                    Text("Volte letto")
                    Spacer()
                    Text("\(draft.timesRead)")
                        .monospacedDigit()
                        .foregroundStyle(Color.pbTextSecondary)
                }
            }
            .onChange(of: draft.timesRead) { Haptics.selection() }
        } header: {
            Text("Letture")
        } footer: {
            Text("Ogni data compare nel diario. Se hai riletto il libro senza ricordare quando, aumenta solo \"Volte letto\".")
        }
        .listRowBackground(Color.pbSurface)
    }

    private var reviewSection: some View {
        Section("Recensione e note personali") {
            ZStack(alignment: .topLeading) {
                if draft.review.isEmpty {
                    Text("Cosa ne pensi? Scrivi la tua recensione, citazioni o note…")
                        .foregroundStyle(Color.pbTextSecondary.opacity(0.7))
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $draft.review)
                    .frame(minHeight: 150)
                    .scrollContentBackground(.hidden)
                    .focused($focusedField, equals: .review)
            }
            .id(Field.review)
        }
        .listRowBackground(Color.pbSurface)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Annulla") {
                if hasChanges {
                    isConfirmingDiscard = true
                } else {
                    dismiss()
                }
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Salva") {
                Task { await save() }
            }
            .fontWeight(.semibold)
            .disabled(!canSave)
        }
        ToolbarItemGroup(placement: .keyboard) {
            Button {
                moveFocus(by: -1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(focusedField == fieldOrder.first)
            .accessibilityLabel("Campo precedente")
            Button {
                moveFocus(by: 1)
            } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(focusedField == fieldOrder.last)
            .accessibilityLabel("Campo successivo")
            Spacer()
            Button("Fine") { focusedField = nil }
                .fontWeight(.semibold)
        }
    }

    // MARK: Foto

    private func openCamera() {
        guard CameraDevices.isAvailable else {
            errorMessage = "La fotocamera non è disponibile su questo dispositivo."
            return
        }
        guard !CameraDevices.isAccessDenied else {
            errorMessage = "L'accesso alla fotocamera è disattivato. Puoi abilitarlo in Impostazioni > Pageboxd."
            return
        }
        isShowingCamera = true
    }

    private func loadPickedPhoto(_ item: PhotosPickerItem) async {
        isProcessingPhoto = true
        defer {
            isProcessingPhoto = false
            photoPickerItem = nil
        }
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data)
            else {
                errorMessage = "Impossibile leggere la foto selezionata."
                return
            }
            let prepared = await ImageStorageManager.shared.preparedImage(from: image, maxPixelDimension: Self.cropWorkingDimension)
            cropSource = CropSource(image: prepared)
        } catch {
            errorMessage = "Impossibile caricare la foto selezionata."
        }
    }

    /// Chiamato alla chiusura della fotocamera: apre il ritaglio solo a presentazione conclusa.
    private func presentCropForCapturedImage() {
        guard let image = capturedImage else { return }
        let quad = capturedQuad
        capturedImage = nil
        capturedQuad = nil
        Task {
            isProcessingPhoto = true
            let prepared = await ImageStorageManager.shared.preparedImage(from: image, maxPixelDimension: Self.cropWorkingDimension)
            isProcessingPhoto = false
            cropSource = CropSource(image: prepared, suggestedQuad: quad)
        }
    }

    /// Riapre il ritaglio sulla foto attuale (appena scelta o già salvata).
    private func cropCurrentPhoto() async {
        if let pickedImage {
            cropSource = CropSource(image: pickedImage)
            return
        }
        guard let path = existingPersonalPhotoPath else { return }
        isProcessingPhoto = true
        defer { isProcessingPhoto = false }
        if let stored = await ImageStorageManager.shared.loadImage(relativePath: path) {
            cropSource = CropSource(image: stored)
        } else {
            errorMessage = "Impossibile aprire la foto salvata."
        }
    }

    private func loadRemoteCover() async {
        guard let url = draft.remoteCoverURL, existingBook?.remoteCoverPath == nil else { return }
        isLoadingRemoteCover = true
        defer { isLoadingRemoteCover = false }
        do {
            let image = try await BookMetadataFetcher.shared.downloadCover(from: url)
            let prepared = await ImageStorageManager.shared.preparedImage(from: image)
            guard !Task.isCancelled else { return }
            remoteCoverImage = prepared
        } catch {
            Logger.pageboxd.info("Copertina del catalogo non disponibile: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Metadati

    private func lookupISBN() async {
        guard let isbn = ISBN.normalize(draft.isbn) else {
            errorMessage = MetadataFetchError.invalidISBN.errorDescription
            Haptics.error()
            return
        }
        focusedField = nil
        isLookingUpISBN = true
        defer { isLookingUpISBN = false }
        do {
            let metadata = try await BookMetadataFetcher.shared.fetch(isbn: isbn)
            draft.fillEmptyFields(from: metadata)
            if draft.language == initialDraft.language, let language = ReadingLanguage.from(isoCode: metadata.languageCode) {
                draft.language = language
                draft.otherLanguageCode = language == .other ? LanguageCatalog.normalizedCode(metadata.languageCode) : nil
            }
            Haptics.success()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            Haptics.warning()
        }
    }

    // MARK: Salvataggio

    private func save() async {
        guard canSave else { return }
        focusedField = nil
        isSaving = true
        defer { isSaving = false }

        let book = existingBook ?? BookItem(title: draft.title.trimmed, author: draft.authorLine)
        let isNew = existingBook == nil

        // 1. Scrittura delle immagini su disco (prima di toccare il database).
        var newPhotoPath: String?
        var newRemoteCoverPath: String?
        do {
            if let pickedImage {
                newPhotoPath = try await ImageStorageManager.shared.save(pickedImage)
            }
            if let remoteCoverImage, book.remoteCoverPath == nil {
                newRemoteCoverPath = try await ImageStorageManager.shared.save(remoteCoverImage)
            }
        } catch {
            ImageStorageManager.shared.deleteImage(relativePath: newPhotoPath)
            errorMessage = error.localizedDescription
            Haptics.error()
            return
        }

        // 2. Aggiornamento del modello.
        var obsoletePaths: [String] = []
        apply(draft, to: book)

        if let newPhotoPath {
            if let oldPath = book.photoPath { obsoletePaths.append(oldPath) }
            book.photoPath = newPhotoPath
        } else if removesExistingPhoto, let oldPath = book.photoPath {
            obsoletePaths.append(oldPath)
            book.photoPath = nil
        }
        if let newRemoteCoverPath {
            book.remoteCoverPath = newRemoteCoverPath
        }

        if isNew {
            modelContext.insert(book)
        }
        book.syncReadingLogs(in: modelContext)

        // 3. Salvataggio atomico; in caso di errore si annulla tutto, file compresi.
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            ImageStorageManager.shared.deleteImage(relativePath: newPhotoPath)
            ImageStorageManager.shared.deleteImage(relativePath: newRemoteCoverPath)
            errorMessage = "Impossibile salvare il libro: \(error.localizedDescription)"
            Haptics.error()
            return
        }

        obsoletePaths.forEach { ImageStorageManager.shared.deleteImage(relativePath: $0) }
        Haptics.success()
        onSaved?(book)
        dismiss()
    }

    private func apply(_ draft: BookDraft, to book: BookItem) {
        book.title = draft.title.trimmed
        book.setAuthors(draft.authorNames)
        book.isbn = draft.normalizedISBN
        book.publicationYear = draft.parsedYear
        book.pageCount = draft.parsedPages
        book.synopsis = draft.synopsis.nilIfBlank
        book.language = draft.language
        book.otherLanguageCode = draft.language == .other ? draft.otherLanguageCode : nil
        book.status = draft.status
        book.rating = BookItem.clampedRating(draft.rating)
        book.liked = draft.liked
        book.review = draft.review.trimmed

        if draft.status == .read {
            let dates = draft.readEntries.map(\.date).sorted(by: >)
            book.readDates = dates.isEmpty ? [Date()] : dates
            book.timesRead = max(draft.timesRead, book.readDates.count)
        }
    }
}
