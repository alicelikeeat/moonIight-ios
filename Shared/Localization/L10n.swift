import Foundation

/// App language. 中文 by default; English, or follow the system.
enum AppLanguage: String, CaseIterable, Sendable {
    case zh, en, system
    var title: String {
        switch self { case .zh: "中文"; case .en: "English"; case .system: L10n.t("跟随系统", "System") }
    }
}

/// Bilingual strings. Each call carries both texts, so a missing
/// translation cannot happen and strings stay next to their use.
enum L10n {
    static let key = "moonlight.language"

    static var language: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .zh
    }

    static var isEnglish: Bool {
        switch language {
        case .zh: false
        case .en: true
        case .system: !(Locale.preferredLanguages.first?.hasPrefix("zh") ?? true)
        }
    }

    static func t(_ zh: String, _ en: String) -> String { isEnglish ? en : zh }
}
