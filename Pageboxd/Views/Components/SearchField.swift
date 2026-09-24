import SwiftUI

/// Campo di ricerca integrato nel contenuto della pagina.
/// Sostituisce la barra di ricerca di sistema (`.searchable`), che in alcune transizioni
/// restava visibile "come un fantasma" sopra i contenuti.
struct SearchField: View {
    @Binding var text: String
    var prompt: String
    var autofocus = false
    var onSubmit: () -> Void = {}

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Color.pbTextSecondary)
                TextField(prompt, text: $text)
                    .focused($isFocused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit(onSubmit)
                if !text.isEmpty {
                    Button {
                        text = ""
                        Haptics.selection()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.pbTextSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cancella ricerca")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(Color.pbSurfaceElevated.opacity(0.8), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            if isFocused {
                Button("Annulla") {
                    text = ""
                    isFocused = false
                }
                .tint(.pbGreen)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.2), value: isFocused)
        .onAppear {
            guard autofocus else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                isFocused = true
            }
        }
    }
}
