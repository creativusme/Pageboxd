import SwiftUI

// MARK: - Selettore a 5 stelle con mezze stelle

/// Tocca la metà sinistra di una stella per la mezza stella, la metà destra per la stella piena.
/// Trascina per scorrere il valore; tocca di nuovo il valore attuale per azzerarlo.
@MainActor
struct StarRatingView: View {
    @Binding var rating: Double
    var starSize: CGFloat = 32
    var spacing: CGFloat = 6
    var isInteractive = true
    var filledColor: Color = .pbGreen
    var emptyColor: Color = Color.pbTextSecondary.opacity(0.35)

    @State private var ratingAtGestureStart: Double? = nil

    private let maxStars = 5

    private var totalWidth: CGFloat {
        CGFloat(maxStars) * starSize + CGFloat(maxStars - 1) * spacing
    }

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(1...maxStars, id: \.self) { index in
                Image(systemName: symbolName(for: index))
                    .resizable()
                    .scaledToFit()
                    .frame(width: starSize, height: starSize)
                    .foregroundStyle(isLit(index) ? filledColor : emptyColor)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .frame(width: totalWidth, height: starSize)
        .contentShape(Rectangle())
        .gesture(ratingGesture)
        .allowsHitTesting(isInteractive)
        .animation(.snappy(duration: 0.15), value: rating)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Valutazione")
        .accessibilityValue(RatingFormatter.spoken(rating))
        .accessibilityAdjustableAction { direction in
            guard isInteractive else { return }
            switch direction {
            case .increment: setRating(min(5, rating + 0.5))
            case .decrement: setRating(max(0, rating - 0.5))
            @unknown default: break
            }
        }
    }

    private func symbolName(for index: Int) -> String {
        let value = rating - Double(index - 1)
        if value >= 1 { return "star.fill" }
        if value >= 0.5 { return "star.leadinghalf.filled" }
        return "star.fill"
    }

    private func isLit(_ index: Int) -> Bool {
        rating - Double(index - 1) >= 0.5
    }

    private var ratingGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if ratingAtGestureStart == nil {
                    ratingAtGestureStart = rating
                }
                setRating(ratingValue(at: value.location.x))
            }
            .onEnded { value in
                let isTap = abs(value.translation.width) < 6 && abs(value.translation.height) < 6
                if isTap, let start = ratingAtGestureStart, start == ratingValue(at: value.location.x) {
                    setRating(0)
                }
                ratingAtGestureStart = nil
            }
    }

    private func ratingValue(at x: CGFloat) -> Double {
        let clampedX = min(max(x, 0), totalWidth - 0.01)
        let unit = starSize + spacing
        let index = min(maxStars - 1, Int(clampedX / unit))
        let offsetInStar = clampedX - CGFloat(index) * unit
        let isHalf = offsetInStar < starSize / 2
        let value = Double(index) + (isHalf ? 0.5 : 1.0)
        return min(Double(maxStars), max(0.5, value))
    }

    private func setRating(_ newValue: Double) {
        guard newValue != rating else { return }
        rating = newValue
        Haptics.impact(.light, intensity: newValue == 0 ? 0.5 : 0.8)
    }
}

// MARK: - Visualizzazione compatta in sola lettura

struct RatingStarsDisplay: View {
    let rating: Double
    var size: CGFloat = 11
    var color: Color = .pbGreen

    var body: some View {
        HStack(spacing: size * 0.12) {
            ForEach(0..<Int(rating), id: \.self) { _ in
                Image(systemName: "star.fill")
            }
            if rating - Double(Int(rating)) >= 0.5 {
                Text("½")
                    .font(.system(size: size * 1.05, weight: .bold))
            }
        }
        .font(.system(size: size))
        .foregroundStyle(color)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(RatingFormatter.spoken(rating))
    }
}

// MARK: - Pulsante "Mi piace"

struct LikeButton: View {
    @Binding var isLiked: Bool
    var size: CGFloat = 30

    var body: some View {
        Button {
            isLiked.toggle()
            Haptics.impact(isLiked ? .medium : .light)
        } label: {
            Image(systemName: isLiked ? "heart.fill" : "heart")
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .foregroundStyle(isLiked ? Color.pbOrange : Color.pbTextSecondary.opacity(0.6))
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: isLiked)
                .frame(width: size + 14, height: size + 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isLiked ? "Rimuovi Mi piace" : "Mi piace")
        .accessibilityAddTraits(isLiked ? .isSelected : [])
    }
}
