import AppKit
import SwiftUI

/// AppKit-backed path control so folder paths render with native macOS styling.
struct PathControlView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSPathControl {
        let control = NSPathControl()
        control.pathStyle = .standard
        control.controlSize = .small
        control.lineBreakMode = .byTruncatingMiddle
        control.isEditable = false
        control.url = url
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return control
    }

    func updateNSView(_ nsView: NSPathControl, context: Context) {
        nsView.url = url
    }
}
