import AppKit

@main
@MainActor
enum BlinkApp {
    private static let controller = AppController()

    static func main() {
        let app = NSApplication.shared
        // LSUIElement in Info.plist keeps us out of the dock; the accessory
        // policy is set here as well so behavior doesn't depend on the plist.
        app.setActivationPolicy(.accessory)
        app.delegate = controller
        app.run()
    }
}
