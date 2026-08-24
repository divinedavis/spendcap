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
/// The reveal is a **horizontal `ScrollView` per row**, snapped by a
/// `ScrollTargetBehavior`. That is not the obvious way to build it; a
/// `DragGesture` is, and it shipped for one build. It had to go because a
/// SwiftUI drag gesture claims the touch the moment it recognises, in any
/// direction — so a finger that rested on a row and then dragged up scrolled
/// nothing at all (user report, 2026-08-23). Two scroll views sort that out in
/// UIKit for free: this one only pans sideways and hands a vertical pan
/// straight back to the page.
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

    private let actionWidth: CGFloat = 84
    private var space: String { "swipeRow.\(rowID)" }
    private let closedAnchor = "closed"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    content
                        .containerRelativeFrame(.horizontal)
                        .id(closedAnchor)
                        .background(alignment: .leading) { offsetReader }
                    if isDeletable {
                        deleteButton
                    }
                }
                .scrollTargetLayout()
            }
            .coordinateSpace(name: space)
            .scrollIndicators(.hidden)
            // Nothing to reveal on an undeletable row, so it must not budge —
            // a row that slides back empty reads as a delete that broke.
            .scrollDisabled(!isDeletable)
            .scrollTargetBehavior(SwipeSnapBehavior(actionWidth: actionWidth))
            .onPreferenceChange(SwipeOffsetKey.self) { offset in
                // Half open counts as open: the snap animates through the
                // middle, and the siblings should be closing by then.
                if offset < -(actionWidth / 2) {
                    if openRowID != rowID { openRowID = rowID }
                } else if offset > -1, openRowID == rowID {
                    openRowID = nil
                }
            }
            .onChange(of: openRowID) { _, newValue in
                guard newValue != rowID else { return }
                withAnimation(.snappy) { proxy.scrollTo(closedAnchor, anchor: .leading) }
            }
        }
    }

    /// How far the row has been pulled open, in the scroll view's own
    /// coordinate space: 0 closed, `-actionWidth` fully open.
    private var offsetReader: some View {
        GeometryReader { geo in
            Color.clear.preference(key: SwipeOffsetKey.self,
                                   value: geo.frame(in: .named(space)).minX)
        }
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            openRowID = nil
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
            .padding(.leading, 8)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(deleteIdentifier ?? "swipeRow.delete")
    }
}

/// Snaps a swiped row to closed or fully open — never to a half-revealed
/// button, which is what free scrolling would leave behind.
private struct SwipeSnapBehavior: ScrollTargetBehavior {
    let actionWidth: CGFloat

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        target.rect.origin.x = target.rect.minX > actionWidth * 0.4 ? actionWidth : 0
    }
}

private struct SwipeOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
