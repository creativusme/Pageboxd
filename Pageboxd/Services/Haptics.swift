import UIKit

/// Feedback aptico centralizzato. Rispetta l'impostazione utente "Feedback aptico".
enum Haptics {
    private static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: AppStorageKeys.hapticsEnabled) as? Bool ?? true
    }

    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle, intensity: CGFloat = 1) {
        guard isEnabled else { return }
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred(intensity: intensity)
    }

    static func selection() {
        guard isEnabled else { return }
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        generator.selectionChanged()
    }

    static func success() { notify(.success) }
    static func warning() { notify(.warning) }
    static func error() { notify(.error) }

    private static func notify(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        guard isEnabled else { return }
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(type)
    }
}
