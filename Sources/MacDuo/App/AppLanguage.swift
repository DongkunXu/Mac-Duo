import Foundation

/// The interface language. By default the app follows the system; choosing a language writes the
/// standard `AppleLanguages` override into the app's own defaults, which macOS reads at launch.
enum AppLanguage: Hashable {
    case system
    case english
    case simplifiedChinese

    private static let key = "AppleLanguages"

    private var code: String? {
        switch self {
        case .system: nil
        case .english: "en"
        case .simplifiedChinese: "zh-Hans"
        }
    }

    static func stored(in defaults: UserDefaults) -> AppLanguage {
        guard let domain = Bundle.main.bundleIdentifier,
              let codes = defaults.persistentDomain(forName: domain)?[key] as? [String],
              let first = codes.first else { return .system }
        return [.english, .simplifiedChinese].first { $0.code == first } ?? .system
    }

    func store(in defaults: UserDefaults) {
        if let code {
            defaults.set([code], forKey: Self.key)
        } else {
            defaults.removeObject(forKey: Self.key)
        }
    }
}
