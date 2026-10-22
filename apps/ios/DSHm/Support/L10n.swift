import Foundation

/// Runtime localization for *dynamic* strings.
///
/// SwiftUI only auto-localizes string literals passed as `LocalizedStringKey`.
/// Values produced by computed properties, enums or view-model code are plain
/// `String`, so they must be localized explicitly against the same String Catalog
/// (`Resources/Localizable.xcstrings`, zh-Hans source + en translations).
///
/// Resolution follows the in-app language switch (`appLanguage` in UserDefaults,
/// written by `AppModel.language.didSet`) and falls back to the system language.
/// Keys are the zh-Hans source strings; formatted keys use `%lld`/`%@` for
/// `String(format:)`.
enum L10n {
    static func t(_ key: String) -> String {
        resolve(key)
    }

    static func f(_ key: String, _ args: CVarArg...) -> String {
        String(format: resolve(key), arguments: args)
    }

 // MARK: - Language resolution

 /// Unit-test host processes are pinned to the zh-Hans source language so the
 /// existing Chinese label assertions stay deterministic (the app bundle is
 /// used as TEST_HOST, and the simulator/system language is en-CN).
    private static var isUnitTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    static var effectiveLanguage: AppLanguage {
        if isUnitTestHost { return .zhHans }
 // Same env contract as AppModel: the E2E screenshot runs pin the language.
        if let forced = ProcessInfo.processInfo.environment["DSHM_FORCE_LANGUAGE"], !forced.isEmpty {
            return forced.lowercased().hasPrefix("en") ? .english : .zhHans
        }
        let stored = AppLanguage.fromStored(UserDefaults.standard.string(forKey: "appLanguage"))
        if stored != .system { return stored }
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
        return preferred.hasPrefix("zh") ? .zhHans : .english
    }

 /// Locale matching `effectiveLanguage` (RelativeDateTimeFormatter & co).
    static var displayLocale: Locale {
        effectiveLanguage == .english ? Locale(identifier: "en_US") : Locale(identifier: "zh_Hans_CN")
    }

    private static func resolve(_ key: String) -> String {
        guard let bundle = bundle(for: effectiveLanguage) else { return key }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    private static func bundle(for language: AppLanguage) -> Bundle? {
        switch language {
        case .english:
            return .main.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:))
        case .zhHans, .system:
            return .main.path(forResource: "zh-Hans", ofType: "lproj").flatMap(Bundle.init(path:))
        }
    }
}
