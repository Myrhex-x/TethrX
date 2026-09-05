import Foundation
import SwiftUI
import ObjectiveC

/// Changing the app's language from inside the app.
///
/// iOS resolves every localized string through `Bundle.main`, and `Bundle.main` is
/// bound to the language the system picked when the process launched. Writing
/// `AppleLanguages` into user defaults changes that for the NEXT launch only, and a
/// setting you have to quit and reopen the app to see is not really a setting.
///
/// So `Bundle.main`'s class is swapped for one that answers `localizedString` out of
/// the chosen `.lproj` instead. That one method is where SwiftUI's `Text`,
/// `String(localized:)` and the string catalog all end up, so a single override moves
/// the whole app at once. The preference is written as well, so the choice survives a
/// relaunch and stays in step with iOS's own per-app Language screen.
@MainActor
final class AppLanguage: ObservableObject {
    static let shared = AppLanguage()
    private static let defaultsKey = "app.language"

    /// The chosen language code, or "" for "follow the system".
    @Published private(set) var code: String

    private init() {
        code = UserDefaults.standard.string(forKey: Self.defaultsKey) ?? ""
        Override.install()
        Override.bundle = Self.bundle(for: code)
    }

    /// Every language this build actually ships, in the reader's own words.
    /// Read from the bundle rather than hard-coded: a list that drifts from what is
    /// installed offers people a language that renders as English.
    static var available: [(code: String, label: String)] {
        Bundle.main.localizations
            .filter { $0 != "Base" }
            .map { code in
                let locale = Locale(identifier: code)
                // Named in the language itself ("Deutsch", not "German"): someone
                // hunting for their own language is not reading the current one.
                // By identifier first, so pt-BR reads "português (Brasil)" and
                // zh-Hans reads "中文（简体）" rather than both losing the half that
                // says which one they are.
                let name = locale.localizedString(forIdentifier: code)
                    ?? locale.localizedString(forLanguageCode: code)
                    ?? Locale.current.localizedString(forIdentifier: code)
                    ?? code
                return (code, name.prefix(1).uppercased() + name.dropFirst())
            }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    var currentLabel: String {
        guard !code.isEmpty else { return String(localized: "System") }
        return Self.available.first { $0.code == code }?.label ?? code
    }

    func set(_ newCode: String) {
        guard newCode != code else { return }
        code = newCode
        Override.bundle = Self.bundle(for: newCode)
        let defaults = UserDefaults.standard
        if newCode.isEmpty {
            // Hand the choice back to iOS rather than pinning the current language,
            // or "System" would mean "whatever it happened to be that day".
            defaults.removeObject(forKey: Self.defaultsKey)
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set(newCode, forKey: Self.defaultsKey)
            defaults.set([newCode], forKey: "AppleLanguages")
        }
        objectWillChange.send()
    }

    /// The locale to hand SwiftUI, so dates, numbers and plural agreement follow the
    /// same language the words do.
    var locale: Locale {
        code.isEmpty ? Locale.autoupdatingCurrent : Locale(identifier: code)
    }

    /// The bundle every `String(loc:)` resolves against.
    ///
    /// Foundation's `String(localized:)` does NOT go through
    /// `Bundle.main.localizedString`, so the class override that moves SwiftUI's
    /// `Text` leaves these strings in whatever language the process launched in.
    /// Handing it the bundle explicitly is the whole of the fix.
    nonisolated static var currentBundle: Bundle { Override.bundle ?? .main }
    /// nil when the app is following the system, where the stock resolution is
    /// already right and should be left alone.
    nonisolated static var overrideBundle: Bundle? { Override.bundle }

    private static func bundle(for code: String) -> Bundle? {
        guard !code.isEmpty else { return nil }
        // Fall back through "pt-BR" -> "pt": a code with no .lproj of its own would
        // otherwise silently resolve to the development language.
        let candidates = [code, String(code.prefix(while: { $0 != "-" }))]
        for candidate in candidates {
            if let path = Bundle.main.path(forResource: candidate, ofType: "lproj"),
               let bundle = Bundle(path: path) {
                return bundle
            }
        }
        return nil
    }

    /// The `Bundle.main` subclass and the box it reads from.
    ///
    /// `localizedString` is called from whatever thread is drawing, so the override
    /// cannot live on the main actor. It changes about once a year in practice, so a
    /// plain lock around it costs nothing.
    private enum Override {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var stored: Bundle?
        nonisolated(unsafe) private static var installed = false

        static var bundle: Bundle? {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }

        static func install() {
            lock.lock(); defer { lock.unlock() }
            guard !installed else { return }
            installed = true
            object_setClass(Bundle.main, OverridingBundle.self)
        }
    }

    private final class OverridingBundle: Bundle, @unchecked Sendable {
        override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
            guard let bundle = Override.bundle else {
                return super.localizedString(forKey: key, value: value, table: tableName)
            }
            return bundle.localizedString(forKey: key, value: value, table: tableName)
        }
    }
}


extension String {
    /// Localized through the language chosen in the app's own settings.
    ///
    /// Every `String(localized:)` in this app is spelled `String(loc:)` for exactly
    /// one reason: the plain initializer ignores the bundle override, and a screen
    /// half in Italian and half in English is worse than either.
    init(loc key: String.LocalizationValue) {
        self.init(localized: key, bundle: AppLanguage.currentBundle)
    }

    /// The same, for a resource that has already bound itself to the main bundle.
    ///
    /// Re-resolving from the key drops any arguments the resource carried, so this
    /// is only for argument-free ones (the command-risk reasons handed to the watch).
    /// Anything with a `%@` in it must reach `Text` instead, which resolves correctly
    /// on its own.
    init(resolving resource: LocalizedStringResource) {
        guard let bundle = AppLanguage.overrideBundle else {
            self.init(localized: resource); return
        }
        self.init(localized: String.LocalizationValue(stringLiteral: resource.key), bundle: bundle)
    }
}
