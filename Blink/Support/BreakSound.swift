import AppKit

enum BreakSound {
    static func playStart() {
        NSSound(named: "Tink")?.play()
    }

    static func playEnd() {
        NSSound(named: "Glass")?.play()
    }
}
