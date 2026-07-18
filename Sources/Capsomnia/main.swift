import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = Capsomnia()
    app.delegate = delegate
    app.run()
}
