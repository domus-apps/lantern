import AppKit

let app = NSApplication.shared
/* Top-level code isn't main-actor-isolated in this language mode, but the
   entry point does run on the main thread. */
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
/* A regular Dock app; set explicitly so a bare `swift run` binary gets a
   menu bar and Dock icon too. */
app.setActivationPolicy(.regular)
app.run()
