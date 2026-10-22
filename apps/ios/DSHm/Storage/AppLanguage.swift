import Foundation

/// In-app language switch (settings). UI literals are localized through
/// Localizable.xcstrings (zh-Hans source strings + English values).
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case zhHans
    case english

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return L10n.t("跟随系统")
        case .zhHans: return L10n.t("简体中文")
        case .english: return "English"
        }
    }

    var locale: Locale? {
        switch self {
        case .system: return nil
        case .zhHans: return Locale(identifier: "zh-Hans")
        case .english: return Locale(identifier: "en")
        }
    }

    var storageKey: String { rawValue }

    static func fromStored(_ value: String?) -> AppLanguage {
        guard let value, let language = AppLanguage(rawValue: value) else { return .system }
        return language
    }
}
