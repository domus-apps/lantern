import AppKit

let app = NSApplication.shared
/* Top-level code isn't main-actor-isolated in this language mode, but the
   entry point does run on the main thread. */
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
/* Menu bar only — no Dock icon. The bundled build also sets LSUIElement,
   but this makes plain `swift run` behave the same way. */
app.setActivationPolicy(.accessory)
app.run()
