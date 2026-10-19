import Foundation

/* UI strings pass through here: the English source text is the key, so a
   missing translation (or a language Lantern doesn't ship) falls back to
   English by construction. Translations live in
   Resources/<lang>.lproj/Localizable.strings inside the SPM resource
   bundle, which follows the user's system language. */

/* Resolved by hand instead of `Bundle.module`: the accessor SwiftPM
   generates for executable targets varies by toolchain, and the classic
   build system's version checks only the .app root and the build
   machine's absolute path — never Contents/Resources, where bundle.sh
   puts the bundle — then traps (Keystone 1.5.0 shipped crashing on
   exactly that). Checking Resources first also spares `Bundle.module`'s
   own trap from ever being reachable in a bundled app. */
private let resourceBundle: Bundle = {
    if let url = Bundle.main.resourceURL?
        .appendingPathComponent("Lantern_Lantern.bundle"),
        let bundle = Bundle(url: url)
    {
        return bundle
    }
    /* `swift run` and Xcode builds: the generated accessor knows the
       build-directory layout for the toolchain that made the binary. */
    return .module
}()

/* The bundled app lists its languages in Info.plist (CFBundleLocalizations)
   and Foundation localizes the resource bundle to match. An executable run
   on its own (`swift run`, dev.sh) has no Info.plist, so Foundation put
   every bundle in the development language and the UI stayed English, on
   a Korean Mac and with -AppleLanguages alike. There the language is
   picked here from the user's preferences, which -AppleLanguages sets. */
private let localizationBundle: Bundle = {
    guard Bundle.main.bundleURL.pathExtension != "app" else { return resourceBundle }
    let available = Set(resourceBundle.localizations).union(["en"])
    /* Explicit preferences, or this follows the main bundle back to
       English; from UserDefaults, which sees -AppleLanguages (Locale's
       list doesn't). */
    let preferences = UserDefaults.standard.stringArray(forKey: "AppleLanguages") ?? Locale.preferredLanguages
    guard let language = Bundle.preferredLocalizations(from: Array(available), forPreferences: preferences).first,
        let path = resourceBundle.path(forResource: language, ofType: "lproj"),
        let localized = Bundle(path: path)
    else { return resourceBundle }  // English: the keys themselves
    return localized
}()

func L(_ key: String) -> String {
    NSLocalizedString(key, bundle: localizationBundle, comment: "")
}

func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: L(key), arguments: arguments)
}
