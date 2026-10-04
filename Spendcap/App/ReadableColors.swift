import SwiftUI
import UIKit

/// Text colours that clear WCAG's 4.5:1 for small text on the app's cards and
/// backgrounds, in both appearances. Added 2026-10-04 when Apple's
/// accessibility audit (SpendcapUITests/AccessibilityAuditTests) became a ship
/// gate and failed the system styles they replace:
///
/// - `.secondary` is #8A8A8E in light mode: 3.4:1 on a white card and 3.1:1
///   on the grouped background — every caption on Debt and Months "nearly
///   passed". `secondaryText` is #636366 (6.0 / 5.4) and #AEAEB2 in dark mode
///   (7.7 on #1C1C1E).
/// - System red (#FF3B30) and orange read 3.6:1 and 2.2:1 as text on white.
///
/// The light-mode AccentColor moved from #34C759 (2.2:1 as text on white) to
/// #1A7F37 (5.1:1) at the same time; dark mode keeps the brand green.
extension Color {
    static let secondaryText = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0xAE / 255, green: 0xAE / 255, blue: 0xB2 / 255, alpha: 1)
            : UIColor(red: 0x63 / 255, green: 0x63 / 255, blue: 0x66 / 255, alpha: 1)
    })

    static let dangerText = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0xFF / 255, green: 0x69 / 255, blue: 0x61 / 255, alpha: 1)
            : UIColor(red: 0xB3 / 255, green: 0x26 / 255, blue: 0x1E / 255, alpha: 1)
    })

    static let warningText = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0xFF / 255, green: 0xB3 / 255, blue: 0x40 / 255, alpha: 1)
            : UIColor(red: 0x9A / 255, green: 0x54 / 255, blue: 0x00 / 255, alpha: 1)
    })
}

extension BudgetMath {
    /// "$762.00" as VoiceOver should say it — "762 dollars" — because the
    /// audit reads a bare currency string as "not human-readable".
    static func spoken(_ cents: Int) -> String {
        let sign = cents < 0 ? "minus " : ""
        let dollars = abs(cents) / 100, rest = abs(cents) % 100
        let d = "\(dollars.formatted()) dollar\(dollars == 1 ? "" : "s")"
        return rest == 0 ? sign + d : sign + d + " and \(rest) cent\(rest == 1 ? "" : "s")"
    }
}
