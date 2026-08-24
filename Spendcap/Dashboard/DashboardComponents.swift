import SwiftUI

// Shared chrome for the Home and Trends templates: a soft page background with
// white rounded "surface" cards stacked on it, section headers with a trailing
// action, and a standard list row. Swap the labels — the layout is the template.

/// Page background the cards sit on. Slightly tinted so white cards read as
/// raised without needing shadows.
struct DashboardBackground: View {
    var body: some View {
        Color(.secondarySystemBackground).ignoresSafeArea()
    }
}

/// White rounded container. Everything on Home and Trends lives in one of these.
struct SurfaceCard<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 18))
    }
}

/// Section title with an optional trailing "..." style action, as on Monzo's
/// Activity card.
struct SectionHeader: View {
    let title: String
    var actionSystemImage: String? = "ellipsis"
    var action: (() -> Void)?

    var body: some View {
        HStack {
            Text(title)
                .font(.title3.weight(.bold))
            Spacer()
            if let actionSystemImage, let action {
                Button(action: action) {
                    Image(systemName: actionSystemImage)
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("\(title) options")
            }
        }
    }
}

/// Rounded-square tinted glyph used as the leading icon on activity and
/// breakdown rows.
struct RowIcon: View {
    let systemName: String
    var tint: Color = .accentColor

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(tint.opacity(0.15))
            .frame(width: 38, height: 38)
            .overlay {
                Image(systemName: systemName)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(tint)
            }
    }
}

/// Generic list row: icon, title, optional subtitle, trailing value.
/// Used for both Activity (Home) and Breakdown (Trends).
struct DashboardRow: View {
    let icon: String
    var tint: Color = .accentColor
    let title: String
    var subtitle: String?
    let value: String
    var valueColor: Color = .primary
    var valueCaption: String?

    var body: some View {
        HStack(spacing: 12) {
            RowIcon(systemName: icon, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(value)
                    .font(.body.weight(.semibold).monospacedDigit())
                    .foregroundStyle(valueColor)
                if let valueCaption {
                    Text(valueCaption)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

/// Pill button used inside the hero card ("Add money" / "Card" on Monzo).
struct HeroPillButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(.bold))
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .background(Color.white.opacity(0.22), in: Capsule())
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }
}

/// Dismissible announcement strip — Monzo's "Your money has a new look" card.
struct AnnouncementCard: View {
    let icon: String
    var tint: Color = .accentColor
    let title: String
    let message: String
    var onDismiss: (() -> Void)?

    var body: some View {
        SurfaceCard {
            HStack(alignment: .top, spacing: 12) {
                RowIcon(systemName: icon, tint: tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                if let onDismiss {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Dismiss")
                }
            }
        }
    }
}

/// Promo card with a full-width CTA — Monzo's "Create category targets".
struct PromptCard: View {
    let icon: String
    var tint: Color = .accentColor
    let title: String
    let message: String
    let ctaTitle: String
    let action: () -> Void

    var body: some View {
        SurfaceCard {
            HStack(alignment: .top, spacing: 12) {
                RowIcon(systemName: icon, tint: tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button(action: action) {
                Text(ctaTitle)
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(tint, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
    }
}

/// Small horizontal card in the "Suggested actions" carousel.
struct SuggestionCard: View {
    let icon: String
    var tint: Color = .accentColor
    let title: String
    let message: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                RowIcon(systemName: icon, tint: tint)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.leading)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(width: 190, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Swipe to delete

/// A row in a card stack that swipes left to reveal a Delete button — the List
/// affordance, rebuilt for the `VStack`-inside-a-`SurfaceCard` layout the
/// dashboard uses (`.swipeActions` only exists inside a `List`).
///
/// The reveal is a drag, attached **simultaneously** so the page's own vertical
/// scroll still receives the same touches, and ignored unless the finger is
/// travelling sideways — the row is a passenger on the page's scroll, not a
/// competitor for it. The first build wrapped each row in its own horizontal
/// `ScrollView` and let `ScrollTargetBehavior` do the snapping; it was dropped
/// because a row that owns a scroll view of its own is one more thing between a
/// finger and the button underneath it, for a snap this can do in four lines.
///
/// Opening a row publishes its id through `openRowID`, so the siblings that see
/// someone else's id close themselves, as rows in a List do.
struct SwipeToDeleteRow<Content: View>: View {
    /// Identifies this row among its siblings.
    let rowID: String
    @Binding var openRowID: String?
    /// A row with nothing to delete (Uncategorized) doesn't swipe at all.
    var isDeletable = true
    var deleteIdentifier: String?
    var deleteLabel = "Delete"
    let onDelete: () -> Void
    @ViewBuilder var content: Content

    @State private var offsetX: CGFloat = 0
    /// True while a swipe is in flight, and for a beat afterwards. The row
    /// underneath watches it so the drag doesn't also read as a tap or a hold:
    /// a finger sliding sideways never leaves the button's frame, so the
    /// button keeps its press the whole way and fires on release.
    @State private var swiping = false
    @State private var settleSwipe: Task<Void, Never>?

    private let actionWidth: CGFloat = 84

    private var isOpen: Bool { openRowID == rowID }

    var body: some View {
        ZStack(alignment: .trailing) {
            if isDeletable {
                deleteButton
                    // Never a touch target while closed — it sits under the
                    // row, and a delete you can hit by accident is worse than
                    // no delete at all.
                    .allowsHitTesting(offsetX < -8)
                    .opacity(offsetX < -2 ? 1 : 0)
            }

            content
                // Opaque, so the button underneath is revealed by the row
                // moving rather than showing through it. Matches SurfaceCard.
                .background(Color(.systemBackground))
                .offset(x: offsetX)
                .environment(\.rowSwipeActive, swiping)
        }
        .clipShape(Rectangle())
        .simultaneousGesture(isDeletable ? swipe : nil)
        .onChange(of: openRowID) { _, newValue in
            guard newValue != rowID, offsetX != 0 else { return }
            withAnimation(.snappy(duration: 0.25)) { offsetX = 0 }
        }
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                // Sideways only. A finger that is mostly travelling down the
                // page is scrolling it, and this gesture is running alongside
                // that scroll rather than instead of it.
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                beginSwipe()
                let base: CGFloat = isOpen ? -actionWidth : 0
                // A little past open, so the pull has somewhere to go and
                // stops dead rather than tearing the row off the card.
                offsetX = min(0, max(-actionWidth - 24, base + value.translation.width))
            }
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                let base: CGFloat = isOpen ? -actionWidth : 0
                // Flick counts as well as distance: a short fast swipe opens.
                let projected = base + value.predictedEndTranslation.width
                setOpen(projected < -actionWidth * 0.5)
                endSwipe()
            }
    }

    private func beginSwipe() {
        settleSwipe?.cancel()
        if !swiping { swiping = true }
    }

    /// Held past the end of the drag: the touch that finishes a swipe is still
    /// down, and its release would otherwise arrive at the button as a tap.
    private func endSwipe() {
        settleSwipe?.cancel()
        settleSwipe = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            swiping = false
        }
    }

    private func setOpen(_ open: Bool) {
        withAnimation(.snappy(duration: 0.25)) {
            offsetX = open ? -actionWidth : 0
        }
        if open {
            openRowID = rowID
        } else if isOpen {
            openRowID = nil
        }
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            setOpen(false)
            onDelete()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "trash")
                    .font(.body.weight(.semibold))
                Text(deleteLabel)
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(.white)
            .frame(width: actionWidth - 8)
            .frame(maxHeight: .infinity)
            .background(Color.red, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(deleteIdentifier ?? "swipeRow.delete")
    }
}

// MARK: - Tap or hold

/// A row that opens on a tap *and* on a hold, staying a Button to the
/// accessibility tree (which is what the UI tests query).
///
/// The hold is timed off the button's own pressed state rather than a
/// `LongPressGesture`. The Button owns the touch, and a long press hung off it
/// with `.simultaneousGesture` or `.highPriorityGesture` never fired in testing
/// (Trends, 2026-08-23) — where the pressed state the button publishes itself
/// arrives every time, and races neither the tap nor the swipe drag beside it.
struct HoldableRow<Label: View>: View {
    var holdDuration: Double = 0.45
    let onTap: () -> Void
    let onHold: () -> Void
    @ViewBuilder var label: Label

    @Environment(\.rowSwipeActive) private var isSwiping
    @State private var didHold = false

    var body: some View {
        Button {
            // Neither the release that ends a hold nor the one that ends a
            // swipe is a tap.
            if didHold { didHold = false; return }
            guard !isSwiping else { return }
            onTap()
        } label: {
            label
        }
        .buttonStyle(HoldButtonStyle(holdDuration: holdDuration, isSuppressed: isSwiping) {
            didHold = true
            onHold()
        })
    }
}

/// Set by a row that is being swiped, read by the button inside it.
private struct RowSwipeActiveKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var rowSwipeActive: Bool {
        get { self[RowSwipeActiveKey.self] }
        set { self[RowSwipeActiveKey.self] = newValue }
    }
}

private struct HoldButtonStyle: ButtonStyle {
    let holdDuration: Double
    /// A swipe is under way: the press belongs to the drag, not to a hold.
    let isSuppressed: Bool
    let onHold: () -> Void

    func makeBody(configuration: Configuration) -> some View {
        HoldTracker(isPressed: configuration.isPressed,
                    holdDuration: holdDuration,
                    isSuppressed: isSuppressed,
                    onHold: onHold) {
            configuration.label
        }
    }

    /// A view, not the style itself: the countdown needs `@State` to survive
    /// the re-render that flipping `isPressed` causes.
    private struct HoldTracker<Content: View>: View {
        let isPressed: Bool
        let holdDuration: Double
        let isSuppressed: Bool
        let onHold: () -> Void
        @ViewBuilder var content: Content

        @State private var countdown: Task<Void, Never>?

        var body: some View {
            content
                .contentShape(Rectangle())
                .opacity(isPressed ? 0.6 : 1)
                .onChange(of: isPressed) { _, pressed in
                    countdown?.cancel()
                    guard pressed, !isSuppressed else { return }
                    countdown = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: UInt64(holdDuration * 1_000_000_000))
                        guard !Task.isCancelled else { return }
                        onHold()
                    }
                }
                // A press that turns into a swipe stops being a hold.
                .onChange(of: isSuppressed) { _, suppressed in
                    if suppressed { countdown?.cancel() }
                }
                .onDisappear { countdown?.cancel() }
        }
    }
}
