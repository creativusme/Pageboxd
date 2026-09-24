import SwiftData
import SwiftUI

@MainActor
struct BookDetailView: View {
    @Bindable var book: BookItem

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var isEditing = false
    @State private var isMarkingAsRead = false
    @State private var isConfirmingDelete = false
    @State private var isShowingPhoto = false
    @State private var isSynopsisExpanded = false
    @State private var isDeleting = false
    @State private var backdropImage: UIImage? = nil

    var body: some View {
        Group {
            if isDeleting {
                Color.pbBackground.ignoresSafeArea()
            } else {
                detailContent
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .sheet(isPresented: $isEditing) {
            AddEditBookView(mode: .edit(book))
        }
        .sheet(isPresented: $isMarkingAsRead) {
            AddEditBookView(mode: .markAsRead(book))
        }
        .fullScreenCover(isPresented: $isShowingPhoto) {
            if let path = book.coverPath {
                PhotoViewer(path: path, title: book.title)
            }
        }
        .confirmationDialog("Eliminare questo libro?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Elimina", role: .destructive, action: deleteBook)
        } message: {
            Text("Il libro, le sue letture e la foto della tua edizione verranno rimossi definitivamente.")
        }
    }

    // MARK: Contenuto

    private var detailContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                badges
                if book.status != .watchlist {
                    ratingCard
                } else {
                    markAsReadButton
                }
                if book.status == .reading {
                    markAsReadButton
                }
                synopsisSection
                reviewSection
                if !book.readDates.isEmpty {
                    readDatesSection
                }
                infoSection
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .background(alignment: .top) { backdrop }
        .background(Color.pbBackground)
        .task(id: book.coverPath) { await loadBackdrop() }
    }

    // MARK: Header

    private var backdrop: some View {
        ZStack {
            if let backdropImage {
                Image(uiImage: backdropImage)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 320)
                    .blur(radius: 30)
                    .opacity(0.55)
                    .clipped()
            }
            LinearGradient(
                colors: [Color.pbBackground.opacity(0.1), Color.pbBackground],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .frame(height: 320)
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 16) {
            Button {
                if book.coverPath != nil { isShowingPhoto = true }
            } label: {
                BookCoverView(path: book.coverPath, title: book.title, author: book.author, cornerRadius: 8, maxPixelSize: 900)
                    .frame(width: 130)
                    .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(book.hasPersonalPhoto ? "Foto della tua edizione" : "Copertina")
            .accessibilityHint(book.coverPath != nil ? "Mostra a schermo intero" : "")

            VStack(alignment: .leading, spacing: 6) {
                Text(book.title)
                    .font(.system(.title2, design: .serif).weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                ForEach(book.authorList, id: \.self) { name in
                    NavigationLink(value: AuthorRoute(name: name)) {
                        HStack(spacing: 4) {
                            Text(name)
                                .font(.headline)
                                .multilineTextAlignment(.leading)
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.bold))
                        }
                        .foregroundStyle(Color.pbTextSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Apri la scheda dell'autore")
                }
                HStack(spacing: 8) {
                    if let year = book.publicationYear {
                        Text(String(year))
                    }
                    if let pages = book.pageCount {
                        Text("\(pages) pagine")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(Color.pbTextSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 24)
    }

    private var badges: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                BadgeView(text: book.status.displayName, systemImage: book.status.systemImage, tint: book.status.tint)
                BadgeView(text: "\(book.language.flag) \(book.languageDisplayName)", tint: book.language.tint)
                if book.status != .watchlist && book.timesRead > 1 {
                    BadgeView(text: "Letto \(book.timesRead) volte", systemImage: "arrow.counterclockwise", tint: .pbBlue)
                }
                if book.hasPersonalPhoto {
                    BadgeView(text: "La mia edizione", systemImage: "camera.fill", tint: .pbOrange)
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.horizontal, -16)
    }

    // MARK: Valutazione

    private var ratingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "La tua valutazione", systemImage: "star")
            HStack(alignment: .center) {
                StarRatingView(rating: $book.rating, starSize: 30)
                Spacer(minLength: 8)
                LikeButton(isLiked: $book.liked, size: 28)
            }
        }
        .pbCard()
        .onChange(of: book.rating) { modelContext.saveLogging() }
        .onChange(of: book.liked) { modelContext.saveLogging() }
    }

    private var markAsReadButton: some View {
        Button {
            isMarkingAsRead = true
        } label: {
            Label("Segna come letto", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(.pbGreen)
    }

    // MARK: Trama e recensione

    @ViewBuilder
    private var synopsisSection: some View {
        if let synopsis = book.synopsis?.nilIfBlank {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "Trama", systemImage: "text.alignleft")
                Text(synopsis)
                    .font(.body)
                    .lineSpacing(3)
                    .lineLimit(isSynopsisExpanded ? nil : 5)
                    .textSelection(.enabled)
                Button(isSynopsisExpanded ? "Mostra meno" : "Mostra tutto") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isSynopsisExpanded.toggle()
                    }
                }
                .font(.subheadline.weight(.semibold))
                .tint(.pbGreen)
            }
        }
    }

    @ViewBuilder
    private var reviewSection: some View {
        if book.status != .watchlist {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title: "La tua recensione", systemImage: "quote.opening")
                if let review = book.review.nilIfBlank {
                    Text(review)
                        .font(.system(.body, design: .serif))
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .pbCard()
                } else {
                    Button {
                        isEditing = true
                    } label: {
                        Label("Scrivi una recensione", systemImage: "square.and.pencil")
                            .font(.subheadline.weight(.semibold))
                    }
                    .tint(.pbGreen)
                }
            }
        }
    }

    private var readDatesSection: some View {
        let dates = book.readDates.sorted()
        return VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Date di lettura", systemImage: "calendar")
            VStack(spacing: 0) {
                ForEach(Array(dates.enumerated().reversed()), id: \.offset) { index, date in
                    HStack {
                        Image(systemName: index == 0 ? "book.closed.fill" : "arrow.counterclockwise")
                            .foregroundStyle(index == 0 ? Color.pbGreen : Color.pbBlue)
                            .frame(width: 24)
                        Text(date.formatted(.dateTime.day().month(.wide).year().locale(.pageboxd)))
                        Spacer()
                        Text(index == 0 ? "Prima lettura" : "Rilettura")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.pbTextSecondary)
                    }
                    .padding(.vertical, 10)
                    if index != 0 {
                        Divider()
                    }
                }
            }
            .pbCard(padding: 12)
        }
    }

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Dettagli", systemImage: "info.circle")
            VStack(spacing: 10) {
                if let isbn = book.isbn {
                    infoRow("ISBN", value: isbn, selectable: true)
                }
                if let year = book.publicationYear {
                    infoRow("Anno", value: String(year))
                }
                if let pages = book.pageCount {
                    infoRow("Pagine", value: "\(pages)")
                }
                infoRow("Lingua di lettura", value: book.languageDisplayName)
                infoRow("Aggiunto il", value: book.dateAdded.formatted(.dateTime.day().month(.wide).year().locale(.pageboxd)))
                infoRow("Copertina", value: coverSourceDescription)
            }
            .pbCard()
        }
    }

    private func infoRow(_ title: String, value: String, selectable: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(Color.pbTextSecondary)
            Spacer(minLength: 12)
            if selectable {
                Text(value)
                    .monospacedDigit()
                    .textSelection(.enabled)
            } else {
                Text(value)
                    .multilineTextAlignment(.trailing)
            }
        }
        .font(.subheadline)
    }

    private var coverSourceDescription: String {
        if book.hasPersonalPhoto { return "Foto della tua edizione" }
        if book.remoteCoverPath != nil { return "Catalogo online" }
        return "Generata"
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button("Modifica") { isEditing = true }
                .disabled(isDeleting)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if book.status != .read {
                    Button {
                        isMarkingAsRead = true
                    } label: {
                        Label("Segna come letto", systemImage: "checkmark.circle")
                    }
                }
                if book.status == .watchlist {
                    Button {
                        book.status = .reading
                        Haptics.impact(.medium)
                        modelContext.saveLogging()
                    } label: {
                        Label("Inizia a leggere", systemImage: "book")
                    }
                }
                ShareLink(item: shareText) {
                    Label("Condividi", systemImage: "square.and.arrow.up")
                }
                Divider()
                Button(role: .destructive) {
                    isConfirmingDelete = true
                } label: {
                    Label("Elimina libro", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .disabled(isDeleting)
            .accessibilityLabel("Altre azioni")
        }
    }

    private var shareText: String {
        var text = "\"\(book.title)\" di \(book.author)"
        if book.isRated { text += " \(RatingFormatter.stars(book.rating))" }
        if book.liked { text += " ♥" }
        if let review = book.review.nilIfBlank { text += "\n\n\(review)" }
        return text
    }

    // MARK: Azioni

    private func loadBackdrop() async {
        guard let path = book.coverPath else {
            backdropImage = nil
            return
        }
        backdropImage = await ImageStorageManager.shared.loadThumbnail(relativePath: path, maxPixelSize: 300)
    }

    /// Chiude prima la schermata e poi elimina il modello, così nessuna vista accede a un oggetto rimosso.
    private func deleteBook() {
        let bookToDelete = book
        let context = modelContext
        isDeleting = true
        Haptics.warning()
        dismiss()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            bookToDelete.deleteWithAssets(from: context)
        }
    }
}

// MARK: - Visualizzatore foto a schermo intero

@MainActor
struct PhotoViewer: View {
    let path: String
    let title: String

    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage? = nil
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(magnification.simultaneously(with: drag))
                    .onTapGesture(count: 2) {
                        withAnimation(.spring(duration: 0.3)) {
                            if scale > 1 {
                                resetZoom()
                            } else {
                                scale = 2.5
                                lastScale = 2.5
                            }
                        }
                    }
                    .accessibilityLabel(title)
            } else {
                ProgressView().tint(.white)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .padding(20)
            .accessibilityLabel("Chiudi")
        }
        .statusBarHidden()
        .task {
            image = await ImageStorageManager.shared.loadImage(relativePath: path)
        }
    }

    private var magnification: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = min(max(lastScale * value.magnification, 1), 5)
            }
            .onEnded { _ in
                lastScale = scale
                if scale <= 1 {
                    withAnimation(.spring(duration: 0.3)) { resetZoom() }
                }
            }
    }

    private var drag: some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1 else { return }
                offset = CGSize(
                    width: lastOffset.width + value.translation.width,
                    height: lastOffset.height + value.translation.height
                )
            }
            .onEnded { value in
                if scale > 1 {
                    lastOffset = offset
                } else if value.translation.height > 120 {
                    dismiss()
                }
            }
    }

    private func resetZoom() {
        scale = 1
        lastScale = 1
        offset = .zero
        lastOffset = .zero
    }
}
