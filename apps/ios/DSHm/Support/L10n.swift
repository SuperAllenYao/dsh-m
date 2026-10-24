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
///
/// cold-launch freeze: the previous implementation resolved the
/// language (UserDefaults / Locale reads) and built a `Bundle` (a disk path
/// lookup + Bundle allocation) on **every** lookup. The workspace list evaluates
/// a couple of localized labels per session card (~50 cards, re-rendered several
/// times during launch), which put hundreds of milliseconds — seconds in Debug —
/// on the main thread (Time Profiler hot stack: `L10n.resolve`). Language, bundle
/// and resolved strings are cached now; `invalidateCache()` is called when the
/// in-app language changes.
enum L10n {
    static func t(_ key: String) -> String {
        resolve(key)
    }

    static func f(_ key: String, _ args: CVarArg...) -> String {
        String(format: resolve(key), arguments: args)
    }

 /// Rebuild the language/bundle/string caches (in-app language switch).
    static func invalidateCache() {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cachedEffectiveLanguage = nil
        cachedBundles.removeAll()
        cachedStrings.removeAll()
    }

 // MARK: - Language resolution

 /// Unit-test host processes are pinned to the zh-Hans source language so the
 /// existing Chinese label assertions stay deterministic (the app bundle is
 /// used as TEST_HOST, and the simulator/system language is en-CN).
    private static var isUnitTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    static var effectiveLanguage: AppLanguage {
        cacheLock.lock()
        if let cached = cachedEffectiveLanguage {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        let language = resolveEffectiveLanguage()
        cacheLock.lock()
        cachedEffectiveLanguage = language
        cacheLock.unlock()
        return language
    }

    private static func resolveEffectiveLanguage() -> AppLanguage {
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

 // MARK: - Caches

    private static let cacheLock = NSLock()
    private static var cachedEffectiveLanguage: AppLanguage?
    private static var cachedBundles: [AppLanguage: Bundle] = [:]
    private static var cachedStrings: [String: String] = [:]

    private static func resolve(_ key: String) -> String {
        let language = effectiveLanguage
        cacheLock.lock()
        if let cached = cachedStrings[key] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        let value = bundle(for: language)?.localizedString(forKey: key, value: key, table: nil) ?? key
        cacheLock.lock()
        cachedStrings[key] = value
        cacheLock.unlock()
        return value
    }

    private static func bundle(for language: AppLanguage) -> Bundle? {
        cacheLock.lock()
        if let cached = cachedBundles[language] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        let resolved: Bundle?
        switch language {
        case .english:
            resolved = Bundle.main.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:))
        case .zhHans, .system:
            resolved = Bundle.main.path(forResource: "zh-Hans", ofType: "lproj").flatMap(Bundle.init(path:))
        }
        if let resolved {
            cacheLock.lock()
            cachedBundles[language] = resolved
            cacheLock.unlock()
        }
        return resolved
    }
}
