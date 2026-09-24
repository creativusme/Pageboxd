import SwiftUI
import UIKit

// MARK: - Palette dinamica (Letterboxd in Dark Mode, pulita e minimale in Light Mode)

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    static func dynamic(light: UInt32, dark: UInt32) -> UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        }
    }

    static let pbBackground = UIColor.dynamic(light: 0xF4F4F6, dark: 0x14181C)
    static let pbSurface = UIColor.dynamic(light: 0xFFFFFF, dark: 0x1C2228)
    static let pbSurfaceElevated = UIColor.dynamic(light: 0xE9EAEE, dark: 0x2C3440)
    static let pbTextSecondary = UIColor.dynamic(light: 0x6B7280, dark: 0x99AABB)
    static let pbGreen = UIColor.dynamic(light: 0x00A843, dark: 0x00E054)
    static let pbOrange = UIColor.dynamic(light: 0xE56F00, dark: 0xFF8000)
    static let pbBlue = UIColor.dynamic(light: 0x1686C4, dark: 0x40BCF4)
    static let pbSeparator = UIColor.dynamic(light: 0xDEDFE4, dark: 0x2C3440)
}

extension Color {
    static let pbBackground = Color(uiColor: .pbBackground)
    static let pbSurface = Color(uiColor: .pbSurface)
    static let pbSurfaceElevated = Color(uiColor: .pbSurfaceElevated)
    static let pbTextSecondary = Color(uiColor: .pbTextSecondary)
    static let pbGreen = Color(uiColor: .pbGreen)
    static let pbOrange = Color(uiColor: .pbOrange)
    static let pbBlue = Color(uiColor: .pbBlue)
    static let pbSeparator = Color(uiColor: .pbSeparator)
}

// MARK: - Tema dell'app

enum ThemeManager {
    /// Applica il tema a tutte le finestre, così anche sheet, alert e controlli UIKit lo rispettano.
    static func apply(_ theme: AppTheme) {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.overrideUserInterfaceStyle = theme.userInterfaceStyle
            }
        }
    }

    /// Stile globale di navigation bar e tab bar.
    static func configureAppearance() {
        // Barra opaca in tinta con lo sfondo: la barra di ricerca non si sovrappone mai ai contenuti.
        let navigationAppearance = UINavigationBarAppearance()
        navigationAppearance.configureWithOpaqueBackground()
        navigationAppearance.backgroundColor = UIColor.pbBackground
        navigationAppearance.shadowColor = .clear
        navigationAppearance.titleTextAttributes = [.font: UIFont.systemFont(ofSize: 17, weight: .semibold)]
        navigationAppearance.largeTitleTextAttributes = [.font: UIFont.systemFont(ofSize: 32, weight: .bold)]

        UINavigationBar.appearance().standardAppearance = navigationAppearance
        UINavigationBar.appearance().compactAppearance = navigationAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navigationAppearance

        let tabAppearance = UITabBarAppearance()
        tabAppearance.configureWithDefaultBackground()
        tabAppearance.backgroundColor = UIColor.pbBackground.withAlphaComponent(0.92)
        tabAppearance.shadowColor = UIColor.pbSeparator
        UITabBar.appearance().standardAppearance = tabAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabAppearance
    }
}

// MARK: - Stili riutilizzabili

struct CardBackground: ViewModifier {
    var cornerRadius: CGFloat = 16
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.pbSurface, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.pbSeparator.opacity(0.6), lineWidth: 0.5)
            )
    }
}

extension View {
    func pbCard(cornerRadius: CGFloat = 16, padding: CGFloat = 16) -> some View {
        modifier(CardBackground(cornerRadius: cornerRadius, padding: padding))
    }

    /// Sfondo coerente per Form e List.
    func pbFormStyle() -> some View {
        scrollContentBackground(.hidden)
            .background(Color.pbBackground)
    }
}

struct SectionTitle: View {
    let title: String
    var systemImage: String?

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(title.uppercased())
                .tracking(1.1)
        }
        .font(.caption.weight(.bold))
        .foregroundStyle(Color.pbTextSecondary)
    }
}
