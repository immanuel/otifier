import Foundation
import Combine

private let selectedLanguageDefaultsKey = "selectedLanguageCode"

struct AppLanguage: Codable, Identifiable {
    let code: String
    let name: String
    let strings: [String: String]

    var id: String { code }
}

private struct LocalizationCatalog: Codable {
    let defaultLanguage: String
    let languages: [AppLanguage]
}

@MainActor
final class LocalizationManager: ObservableObject {
    @Published private(set) var selectedLanguageCode: String
    private(set) var availableLanguages: [AppLanguage]

    private let defaultLanguageCode: String
    private let languagesByCode: [String: AppLanguage]
    private let defaults: UserDefaults

    init(bundle: Bundle = .main, defaults: UserDefaults = .standard) {
        let catalog = Self.loadCatalog(from: bundle)
        self.defaults = defaults
        defaultLanguageCode = catalog.defaultLanguage
        availableLanguages = catalog.languages
        languagesByCode = Dictionary(uniqueKeysWithValues: catalog.languages.map { ($0.code, $0) })

        if let saved = defaults.string(forKey: selectedLanguageDefaultsKey),
           languagesByCode[saved] != nil {
            selectedLanguageCode = saved
        } else {
            selectedLanguageCode = Self.bestLanguageCode(
                for: Locale.preferredLanguages,
                available: catalog.languages.map(\.code),
                fallback: catalog.defaultLanguage
            )
        }
    }

    func setLanguage(_ code: String) {
        guard languagesByCode[code] != nil else { return }
        selectedLanguageCode = code
        defaults.set(code, forKey: selectedLanguageDefaultsKey)
    }

    func text(_ key: String, _ arguments: CVarArg...) -> String {
        let selected = languagesByCode[selectedLanguageCode]?.strings[key]
        let fallback = languagesByCode[defaultLanguageCode]?.strings[key]
        let template = selected ?? fallback ?? key
        guard !arguments.isEmpty else { return template }
        return String(
            format: template,
            locale: Locale(identifier: selectedLanguageCode),
            arguments: arguments
        )
    }

    private static func loadCatalog(from bundle: Bundle) -> LocalizationCatalog {
        guard let url = bundle.url(forResource: "Localizations", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(LocalizationCatalog.self, from: data),
              !catalog.languages.isEmpty,
              catalog.languages.contains(where: { $0.code == catalog.defaultLanguage }) else {
            return LocalizationCatalog(
                defaultLanguage: "en",
                languages: [AppLanguage(code: "en", name: "English", strings: [:])]
            )
        }
        return catalog
    }

    private static func bestLanguageCode(
        for preferredLanguages: [String],
        available: [String],
        fallback: String
    ) -> String {
        for preferred in preferredLanguages {
            if let exact = available.first(where: { $0.caseInsensitiveCompare(preferred) == .orderedSame }) {
                return exact
            }

            let normalized = preferred.lowercased()
            if normalized.hasPrefix("zh-hant") || normalized.hasPrefix("zh-tw") || normalized.hasPrefix("zh-hk"),
               available.contains("zh-Hant") {
                return "zh-Hant"
            }
            if normalized.hasPrefix("zh"), available.contains("zh-Hans") {
                return "zh-Hans"
            }

            let base = normalized.split(separator: "-").first.map(String.init) ?? normalized
            if let match = available.first(where: { $0.lowercased() == base }) {
                return match
            }
        }
        return available.contains(fallback) ? fallback : (available.first ?? "en")
    }
}
