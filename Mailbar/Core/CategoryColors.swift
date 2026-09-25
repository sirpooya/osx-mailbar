import SwiftUI

/// Outlook's category colours, so an event is drawn in the colour its category has in OWA and
/// Outlook (2026-09-25, the user's request).
///
/// An event carries only category NAMES. The colour of each name lives in the mailbox's master
/// category list, a user configuration item called `CategoryList` in the calendar folder, whose
/// XML gives each category a `color` from 0 to 24: Outlook's 25 preset colours, in this order.
/// When that list cannot be read, the name itself is the hint: OWA's defaults are called "Blue
/// category", "Green category" and so on.
enum CategoryColors {
    /// Outlook's presets 0 to 24: Red, Orange, Peach, Yellow, Green, Teal, Olive, Blue, Purple,
    /// Maroon, Steel, Dark Steel, Gray, Dark Gray, Black, then the dark variants of the first ten.
    static let palette: [UInt32] = [
        0xE7_A1_A2, 0xF9_BA_89, 0xF7_DD_8F, 0xFC_FA_90, 0x78_D1_68, 0x9F_DC_C9, 0xC6_D2_B0, 0x9D_B7_E8,
        0xB5_A1_E2, 0xDA_AE_C2, 0xDA_D9_DC, 0x6B_79_94, 0xBF_BF_BF, 0x6F_6F_6F, 0x4F_4F_4F, 0xC1_1A_25,
        0xE2_62_0D, 0xC7_99_30, 0xB9_B3_00, 0x36_8F_2B, 0x32_9B_7A, 0x77_8B_45, 0x28_58_A5, 0x5C_3F_A3,
        0x93_44_6B,
    ]

    static func color(index: Int) -> Color? {
        guard palette.indices.contains(index) else { return nil }
        let value = palette[index]
        return Color(.sRGB,
                     red: Double((value >> 16) & 0xFF) / 255,
                     green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }

    /// The preset a DEFAULT category name implies, for when the master list is out of reach.
    /// Exact names only: matching a colour word anywhere in the name turned "Core Weekly"'s
    /// category red (2026-09-25) because the name happened to contain "red".
    static func guessedIndex(forName name: String) -> Int? {
        let defaults: [String: Int] = ["red category": 0, "orange category": 1, "yellow category": 3,
                                       "green category": 4, "blue category": 7, "purple category": 8]
        return defaults[name.trimmingCharacters(in: .whitespaces).lowercased()]
    }

    /// No colour: `color="-1"` in the master list. Outlook and OWA draw such an event grey.
    static let noColor = -1

    /// Outlook's look for a category that has no colour: a light grey block with a grey bar.
    static let neutral = Color(white: 0.62)

    /// Name to preset index from the master list's XML:
    /// `<categories><category name="Storybook" color="9" .../></categories>`.
    static func parseMasterList(_ xml: Data) -> [String: Int] {
        guard let root = try? XMLTree.parse(xml) else { return [:] }
        var result: [String: Int] = [:]
        for category in root.all("category") where category.name == "category" {
            guard let name = category.attributes["name"],
                  let color = category.attributes["color"].flatMap(Int.init) else { continue }
            // Kept even when -1: "no colour" is an answer from the server, not a gap to guess over.
            result[name] = palette.indices.contains(color) ? color : noColor
        }
        return result
    }
}
