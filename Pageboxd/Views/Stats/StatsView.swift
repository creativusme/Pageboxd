import Charts
import SwiftData
import SwiftUI

@MainActor
struct StatsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var books: [BookItem]
    @Query(sort: \ReadingLog.date) private var logs: [ReadingLog]

    @State private var timeScale: TimeScale = .month
    @State private var selectedYear = Calendar.current.component(.year, from: Date())
    @State private var isCompletingPages = false
    @State private var completionMessage: String? = nil

    enum TimeScale: String, CaseIterable, Identifiable {
        case month
        case year

        var id: String { rawValue }

        var title: String {
            switch self {
            case .month: return "Per mese"
            case .year: return "Per anno"
            }
        }
    }

    // MARK: Dati di base

    private var readBooks: [BookItem] { books.filter { $0.status == .read } }

    private var readingDates: [Date] {
        logs.compactMap { log in
            guard let book = log.book, book.status != .watchlist else { return nil }
            return log.date
        }
    }

    private var availableYears: [Int] {
        let calendar = Calendar.current
        var years = Set(readingDates.map { calendar.component(.year, from: $0) })
        years.insert(calendar.component(.year, from: Date()))
        return years.sorted()
    }

    var body: some View {
        NavigationStack {
            Group {
                if readBooks.isEmpty && readingDates.isEmpty {
                    ContentUnavailableView {
                        Label("Ancora nessuna statistica", systemImage: "chart.bar.xaxis")
                    } description: {
                        Text("Segna i libri come letti per vedere grafici e numeri sulle tue letture.")
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 16) {
                            kpiGrid
                            if !booksMissingPages.isEmpty {
                                missingPagesCard
                            }
                            readingsChartCard
                            ratingsChartCard
                            languageChartCard
                        }
                        .padding(16)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.pbBackground)
            .navigationTitle("Statistiche")
            .alert("Dati completati", isPresented: Binding(isPresent: $completionMessage)) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(completionMessage ?? "")
            }
        }
    }

    // MARK: KPI

    private var kpiGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            KPICard(
                title: "Libri letti",
                value: readBooks.count.formatted(.number.locale(.pageboxd)),
                subtitle: "\(readingsThisYear) letture nel \(String(Calendar.current.component(.year, from: Date())))",
                systemImage: "books.vertical.fill",
                tint: .pbGreen
            )
            KPICard(
                title: "Pagine totali lette",
                value: totalPagesRead.formatted(.number.locale(.pageboxd)),
                subtitle: booksMissingPages.isEmpty
                    ? "Riletture incluse"
                    : "\(booksMissingPages.count) \(booksMissingPages.count == 1 ? "libro" : "libri") senza pagine",
                systemImage: "doc.text.fill",
                tint: .pbBlue
            )
            KPICard(
                title: "Autore più letto",
                value: mostReadAuthor?.name ?? "—",
                subtitle: mostReadAuthor.map { $0.count == 1 ? "1 libro" : "\($0.count) libri" } ?? "Nessun dato",
                systemImage: "person.fill",
                tint: .pbOrange
            )
            KPICard(
                title: "Più riletto",
                value: mostReread?.title ?? "—",
                subtitle: mostReread.map { "Letto \($0.timesRead) volte" } ?? "Nessuna rilettura",
                systemImage: "arrow.counterclockwise",
                tint: .pbBlue
            )
            KPICard(
                title: "Con il cuore",
                value: likedShare.formatted(.percent.precision(.fractionLength(0)).locale(.pageboxd)),
                subtitle: "\(readBooks.filter(\.liked).count) su \(readBooks.count) libri",
                systemImage: "heart.fill",
                tint: .pbOrange
            )
            KPICard(
                title: "Voto medio",
                value: averageRating.map { $0.formatted(.number.precision(.fractionLength(1)).locale(.pageboxd)) + " ★" } ?? "—",
                subtitle: "\(ratedBooks.count) libri valutati",
                systemImage: "star.fill",
                tint: .pbGreen
            )
        }
    }

    private var readingsThisYear: Int {
        let calendar = Calendar.current
        let year = calendar.component(.year, from: Date())
        return readingDates.filter { calendar.component(.year, from: $0) == year }.count
    }

    private var totalPagesRead: Int {
        readBooks.reduce(0) { $0 + ($1.pageCount ?? 0) * $1.timesRead }
    }

    /// Libri letti senza numero di pagine: escludendoli il totale risulterebbe incompleto.
    private var booksMissingPages: [BookItem] {
        readBooks.filter { ($0.pageCount ?? 0) <= 0 }
    }

    private var missingPagesCard: some View {
        let withISBN = booksMissingPages.filter { $0.isbn != nil }.count
        return VStack(alignment: .leading, spacing: 12) {
            Label {
                Text(booksMissingPages.count == 1
                     ? "1 libro letto non ha il numero di pagine, quindi il totale è incompleto."
                     : "\(booksMissingPages.count) libri letti non hanno il numero di pagine, quindi il totale è incompleto.")
                    .font(.subheadline)
            } icon: {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(Color.pbOrange)
            }

            if withISBN > 0 {
                Button {
                    Task { await completeMissingPages() }
                } label: {
                    HStack {
                        Label("Recupera dai cataloghi (\(withISBN))", systemImage: "arrow.down.circle")
                            .font(.subheadline.weight(.semibold))
                        if isCompletingPages {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .buttonStyle(.bordered)
                .tint(.pbGreen)
                .disabled(isCompletingPages)
            }
            if withISBN < booksMissingPages.count {
                Text("Per i libri senza ISBN puoi inserire le pagine dalla scheda del libro › Modifica.")
                    .font(.caption)
                    .foregroundStyle(Color.pbTextSecondary)
            }
        }
        .pbCard()
    }

    /// Completa pagine (e anno/trama se mancanti) usando l'ISBN dei libri letti.
    private func completeMissingPages() async {
        isCompletingPages = true
        defer { isCompletingPages = false }

        let targets = booksMissingPages.filter { $0.isbn != nil }
        var updated = 0
        for book in targets {
            guard let isbn = book.isbn,
                  let metadata = try? await BookMetadataFetcher.shared.fetch(isbn: isbn)
            else { continue }
            if let pages = metadata.pageCount, pages > 0 {
                book.pageCount = pages
                updated += 1
            }
            if book.publicationYear == nil { book.publicationYear = metadata.publicationYear }
            if book.synopsis == nil { book.synopsis = metadata.synopsis }
        }
        modelContext.saveLogging()

        let missing = targets.count - updated
        if updated > 0 {
            Haptics.success()
        } else {
            Haptics.warning()
        }
        completionMessage = updated == 0
            ? "I cataloghi non hanno il numero di pagine per questi libri. Puoi inserirlo a mano dalla scheda del libro."
            : "Pagine aggiunte a \(updated) \(updated == 1 ? "libro" : "libri")." + (missing > 0 ? " \(missing) non trovati nei cataloghi." : "")
    }

    private var mostReadAuthor: (name: String, count: Int)? {
        // Ogni coautore conta: un libro scritto a quattro mani vale per entrambi.
        let authors = readBooks.flatMap(\.authorList).filter { !$0.trimmed.isEmpty }
        let grouped = Dictionary(grouping: authors) { TextMatching.authorKey($0) }
        guard let best = grouped.max(by: { lhs, rhs in
            if lhs.value.count != rhs.value.count { return lhs.value.count < rhs.value.count }
            return lhs.key > rhs.key
        }), let displayName = best.value.first?.trimmed else { return nil }
        return (displayName, best.value.count)
    }

    private var mostReread: BookItem? {
        readBooks
            .filter { $0.timesRead > 1 }
            .max { lhs, rhs in
                if lhs.timesRead != rhs.timesRead { return lhs.timesRead < rhs.timesRead }
                return lhs.rating < rhs.rating
            }
    }

    private var likedShare: Double {
        guard !readBooks.isEmpty else { return 0 }
        return Double(readBooks.filter(\.liked).count) / Double(readBooks.count)
    }

    private var ratedBooks: [BookItem] { readBooks.filter(\.isRated) }

    private var averageRating: Double? {
        guard !ratedBooks.isEmpty else { return nil }
        return ratedBooks.reduce(0) { $0 + $1.rating } / Double(ratedBooks.count)
    }

    // MARK: Grafico letture per periodo

    private var readingsChartCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionTitle(title: "Letture", systemImage: "chart.bar.fill")
                Spacer()
                if timeScale == .month {
                    yearSelector
                }
            }

            Picker("Periodo", selection: $timeScale) {
                ForEach(TimeScale.allCases) { scale in
                    Text(scale.title).tag(scale)
                }
            }
            .pickerStyle(.segmented)

            let data = timeScale == .month ? monthlyData : yearlyData
            Chart(data) { item in
                BarMark(
                    x: .value("Periodo", item.label),
                    y: .value("Letture", item.count)
                )
                .foregroundStyle(Color.pbGreen.gradient)
                .cornerRadius(4)
                .annotation(position: .top, spacing: 2) {
                    if item.count > 0 {
                        Text("\(item.count)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.pbTextSecondary)
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine().foregroundStyle(Color.pbSeparator)
                    AxisValueLabel()
                }
            }
            .chartXAxis {
                AxisMarks { _ in
                    AxisValueLabel()
                        .font(.system(size: 9, weight: .medium))
                }
            }
            .frame(height: 200)
            .animation(.easeInOut, value: timeScale)
            .animation(.easeInOut, value: selectedYear)

            Text(periodSummary(for: data))
                .font(.footnote)
                .foregroundStyle(Color.pbTextSecondary)
        }
        .pbCard()
    }

    private var yearSelector: some View {
        HStack(spacing: 4) {
            Button {
                changeYear(by: -1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(selectedYear <= (availableYears.first ?? selectedYear))

            Text(String(selectedYear))
                .font(.subheadline.weight(.bold))
                .monospacedDigit()
                .frame(minWidth: 44)

            Button {
                changeYear(by: 1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(selectedYear >= (availableYears.last ?? selectedYear))
        }
        .buttonStyle(.borderless)
        .tint(.pbGreen)
    }

    private func changeYear(by delta: Int) {
        selectedYear += delta
        Haptics.selection()
    }

    private var monthlyData: [PeriodCount] {
        let calendar = Calendar.current
        let symbols = Calendar.pageboxd.shortMonthSymbols
        var counts = Array(repeating: 0, count: 12)
        for date in readingDates where calendar.component(.year, from: date) == selectedYear {
            counts[calendar.component(.month, from: date) - 1] += 1
        }
        return (0..<12).map { index in
            PeriodCount(
                id: "\(selectedYear)-\(index)",
                label: symbols[index].replacingOccurrences(of: ".", with: "").capitalized(with: .pageboxd),
                count: counts[index]
            )
        }
    }

    private var yearlyData: [PeriodCount] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: readingDates) { calendar.component(.year, from: $0) }
        guard let first = grouped.keys.min(), let last = grouped.keys.max() else { return [] }
        return (first...last).map { year in
            PeriodCount(id: "\(year)", label: String(year), count: grouped[year]?.count ?? 0)
        }
    }

    private func periodSummary(for data: [PeriodCount]) -> String {
        let total = data.reduce(0) { $0 + $1.count }
        let noun = total == 1 ? "lettura" : "letture"
        switch timeScale {
        case .month:
            return "\(total) \(noun) nel \(String(selectedYear))"
        case .year:
            return "\(total) \(noun) in totale"
        }
    }

    // MARK: Istogramma valutazioni

    private var ratingsChartCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(title: "Distribuzione valutazioni", systemImage: "star.fill")

            if ratedBooks.isEmpty {
                Text("Valuta i tuoi libri per vedere la distribuzione.")
                    .font(.subheadline)
                    .foregroundStyle(Color.pbTextSecondary)
            } else {
                Chart(ratingDistribution) { bucket in
                    BarMark(
                        x: .value("Stelle", bucket.label),
                        y: .value("Libri", bucket.count)
                    )
                    .foregroundStyle(bucket.value >= 4 ? Color.pbGreen.gradient : Color.pbTextSecondary.opacity(0.6).gradient)
                    .cornerRadius(3)
                    .annotation(position: .top, spacing: 2) {
                        if bucket.count > 0 {
                            Text("\(bucket.count)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Color.pbTextSecondary)
                        }
                    }
                }
                .chartYAxis(.hidden)
                .chartXAxis {
                    AxisMarks { _ in
                        AxisValueLabel()
                            .font(.system(size: 10, weight: .semibold))
                    }
                }
                .frame(height: 160)
            }
        }
        .pbCard()
    }

    private var ratingDistribution: [RatingBucket] {
        stride(from: 0.5, through: 5.0, by: 0.5).map { value in
            RatingBucket(
                value: value,
                label: Self.ratingLabel(value),
                count: ratedBooks.filter { $0.rating == value }.count
            )
        }
    }

    private static func ratingLabel(_ value: Double) -> String {
        let whole = Int(value)
        let hasHalf = value - Double(whole) >= 0.5
        if whole == 0 { return "½" }
        return "\(whole)" + (hasHalf ? "½" : "")
    }

    // MARK: Ciambella lingue

    private var languageChartCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(title: "Lingue di lettura", systemImage: "globe")

            HStack(spacing: 20) {
                ZStack {
                    Chart(languageShares) { share in
                        SectorMark(
                            angle: .value("Libri", share.count),
                            innerRadius: .ratio(0.62),
                            angularInset: 2
                        )
                        .cornerRadius(4)
                        .foregroundStyle(share.language.tint)
                    }
                    .chartLegend(.hidden)

                    VStack(spacing: 0) {
                        Text("\(readBooks.count)")
                            .font(.title2.weight(.bold))
                            .monospacedDigit()
                        Text(readBooks.count == 1 ? "libro" : "libri")
                            .font(.caption)
                            .foregroundStyle(Color.pbTextSecondary)
                    }
                }
                .frame(width: 150, height: 150)

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(languageShares) { share in
                        HStack(spacing: 10) {
                            Circle()
                                .fill(share.language.tint)
                                .frame(width: 10, height: 10)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(share.language.flag) \(share.language.displayName)")
                                    .font(.subheadline.weight(.semibold))
                                Text("\(share.percentage.formatted(.percent.precision(.fractionLength(0)).locale(.pageboxd))) · \(share.count)")
                                    .font(.caption)
                                    .foregroundStyle(Color.pbTextSecondary)
                                if share.language == .other, let breakdown = otherLanguagesBreakdown {
                                    Text(breakdown)
                                        .font(.caption2)
                                        .foregroundStyle(Color.pbTextSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .pbCard()
    }

    /// Es. "Francese 3 · Spagnolo 1" per i libri letti in altre lingue.
    private var otherLanguagesBreakdown: String? {
        let others = readBooks.filter { $0.language == .other }
        guard !others.isEmpty else { return nil }
        let grouped = Dictionary(grouping: others) { $0.languageDisplayName }
        return grouped
            .sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key }
            .map { "\($0.key) \($0.value.count)" }
            .joined(separator: " · ")
    }

    private var languageShares: [LanguageShare] {
        let total = readBooks.count
        guard total > 0 else { return [] }
        return ReadingLanguage.allCases.compactMap { language in
            let count = readBooks.filter { $0.language == language }.count
            guard count > 0 else { return nil }
            return LanguageShare(language: language, count: count, percentage: Double(count) / Double(total))
        }
    }
}

// MARK: - Modelli dei grafici

private struct PeriodCount: Identifiable {
    let id: String
    let label: String
    let count: Int
}

private struct RatingBucket: Identifiable {
    var id: Double { value }
    let value: Double
    let label: String
    let count: Int
}

private struct LanguageShare: Identifiable {
    var id: String { language.rawValue }
    let language: ReadingLanguage
    let count: Int
    let percentage: Double
}

// MARK: - Card KPI

private struct KPICard: View {
    let title: String
    let value: String
    let subtitle: String
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.pbTextSecondary)

            Text(value)
                .font(.title3.weight(.bold))
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .fixedSize(horizontal: false, vertical: true)

            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(Color.pbTextSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .pbCard(cornerRadius: 16, padding: 14)
        .accessibilityElement(children: .combine)
    }
}
