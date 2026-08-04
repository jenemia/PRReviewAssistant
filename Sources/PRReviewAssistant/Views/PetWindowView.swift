import AppKit
import SwiftUI

struct PetWindowView: View {
    @Bindable var store: ReviewStore
    let activateMainWindow: () -> Void
    @State private var showsBubble = false
    @State private var isAnimating = false
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: activateMainWindow) {
                mascot
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                showsBubble.toggle()
            } label: {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(9)
                    .background(Circle().fill(BrandColor.prPurple).shadow(color: .black.opacity(0.2), radius: 4, y: 2))
            }
            .buttonStyle(.plain)
            .padding(4)
            .popover(isPresented: $showsBubble, arrowEdge: .bottom) {
                PetBubbleView(content: store.petBubbleContent)
            }
            .accessibilityLabel("최신 PR 보기")
        }
        .onAppear { isAnimating = true }
        .onChange(of: store.petState) { _, _ in isAnimating = false; isAnimating = true }
        .onChange(of: store.petNotificationEventID) { _, _ in
            showsBubble = true
        }
    }

    private var mascot: some View {
        Image(nsImage: mascotImage)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .padding(8)
            .scaleEffect(scale)
            .rotationEffect(.degrees(rotation))
            .offset(y: verticalOffset)
            .shadow(color: statusColor.opacity(0.35), radius: glowRadius)
            .animation(animation, value: isAnimating)
            .accessibilityLabel("PR 리뷰 도우미 펫")
    }

    private var mascotImage: NSImage {
        guard let url = Bundle.main.url(forResource: "PetMascotShield", withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            return NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: nil) ?? NSImage()
        }
        return image
    }

    private var shouldReduceMotion: Bool { store.petReduceMotion || accessibilityReduceMotion }
    private var scale: CGFloat {
        guard !shouldReduceMotion else { return 1 }
        switch store.petState {
        // The idle pet stays still. A perpetual animation here kept the app's
        // renderer active even when no PR work was running.
        case .idle: return 1
        case .attention: return isAnimating ? 1.08 : 0.96
        case .working: return isAnimating ? 1.035 : 0.975
        case .completed: return isAnimating ? 1.1 : 0.96
        }
    }
    private var rotation: Double {
        guard !shouldReduceMotion else { return 0 }
        switch store.petState {
        case .idle: return 0
        case .attention: return isAnimating ? 3 : -3
        case .working: return isAnimating ? 2 : -2
        case .completed: return isAnimating ? 5 : -5
        }
    }
    private var verticalOffset: CGFloat {
        guard !shouldReduceMotion else { return 0 }
        switch store.petState {
        case .idle: return 0
        case .attention: return isAnimating ? -8 : 2
        case .working: return isAnimating ? -4 : 4
        case .completed: return isAnimating ? -10 : 2
        }
    }
    private var animation: Animation? {
        guard !shouldReduceMotion else { return nil }
        switch store.petState {
        case .idle: return nil
        case .attention: return Animation.spring(response: 0.32, dampingFraction: 0.45).repeatForever(autoreverses: true)
        case .working: return Animation.easeInOut(duration: 0.55).repeatForever(autoreverses: true)
        case .completed: return Animation.spring(response: 0.42, dampingFraction: 0.42).repeatCount(3, autoreverses: true)
        }
    }
    private var statusColor: Color {
        switch store.petState {
        case .idle: .clear
        case .attention: .orange
        case .working: .blue
        case .completed: .green
        }
    }
    private var glowRadius: CGFloat { store.petState == .idle ? 0 : 8 }
}

private struct PetBubbleView: View {
    let content: PetBubbleContent

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(content.title)
                .font(.headline)
                .lineLimit(2)
            Text(content.subtitle)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(content.body)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(14)
        .frame(width: 260, alignment: .leading)
    }
}
