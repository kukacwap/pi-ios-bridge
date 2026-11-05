import SwiftUI
import UIKit

/// Alternate app-icon support. The primary icon uses `nil` (asset name "AppIcon");
/// alternates are named to match the *.appiconset folders in Assets.xcassets and
/// the ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES build setting.
enum AppIconOption: String, CaseIterable, Identifiable {
    case primary
    case alt

    var id: String { rawValue }

    /// Value passed to setAlternateIconName (nil = primary).
    var iconName: String? {
        switch self {
        case .primary: return nil
        case .alt:     return "AppIconAlt"
        }
    }

    var label: String {
        switch self {
        case .primary: return "Icon 1"
        case .alt:     return "Icon 2"
        }
    }
}

@MainActor
enum AppIcons {
    static var supported: Bool { UIApplication.shared.supportsAlternateIcons }

    static var current: AppIconOption {
        let name = UIApplication.shared.alternateIconName
        return AppIconOption.allCases.first { $0.iconName == name } ?? .primary
    }

    static func set(_ option: AppIconOption) {
        guard supported, UIApplication.shared.alternateIconName != option.iconName else { return }
        UIApplication.shared.setAlternateIconName(option.iconName) { error in
            if let error = error {
                print("setAlternateIconName failed: \(error.localizedDescription)")
            }
        }
    }
}
