import SwiftUI

/// Elenco ricercabile delle lingue, usato quando la lingua di lettura è "Altro".
struct LanguagePickerView: View {
    @Binding var selection: String?

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var filtered: [(code: String, name: String)] {
        let query = searchText.trimmed
        guard !query.isEmpty else { return LanguageCatalog.all }
        return LanguageCatalog.all.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.code.localizedCaseInsensitiveContains(query)
        }
    }

    private var common: [(code: String, name: String)] {
        LanguageCatalog.commonCodes.compactMap { code in
            LanguageCatalog.name(for: code).map { (code: code, name: $0) }
        }
    }

    var body: some View {
        List {
            if searchText.trimmed.isEmpty {
                Section("Più comuni") {
                    ForEach(common, id: \.code) { language in
                        row(language)
                    }
                }
            }
            Section(searchText.trimmed.isEmpty ? "Tutte le lingue" : "Risultati") {
                ForEach(filtered, id: \.code) { language in
                    row(language)
                }
            }
        }
        .listStyle(.insetGrouped)
        .pbFormStyle()
        .navigationTitle("Lingua di lettura")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top) {
            SearchField(text: $searchText, prompt: "Cerca una lingua")
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.pbBackground)
        }
        .scrollDismissesKeyboard(.immediately)
    }

    private func row(_ language: (code: String, name: String)) -> some View {
        Button {
            selection = language.code
            Haptics.selection()
            dismiss()
        } label: {
            HStack {
                Text(language.name)
                    .foregroundStyle(Color.primary)
                Spacer()
                Text(language.code.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.pbTextSecondary)
                if selection == language.code {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.pbGreen)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.pbSurface)
    }
}
