import AppKit
import SwiftUI

/// AppKit-backed single-line label so text uses macOS's native Cocoa text
/// stack (crisp font smoothing and vibrancy on 1x non-Retina external displays,
/// matching Apple's Control Center Sound/Bluetooth menus).
struct NativeLabel: NSViewRepresentable {
    let text: String
    var font: NSFont = .systemFont(ofSize: 13, weight: .regular)
    var color: NSColor = .labelColor

    func makeNSView(context _: Context) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.allowsDefaultTighteningForTruncation = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.required, for: .vertical)
        return field
    }

    func updateNSView(_ field: NSTextField, context _: Context) {
        if field.stringValue != text { field.stringValue = text }
        if field.font != font { field.font = font }
        if field.textColor != color { field.textColor = color }
    }
}

/// AppKit-backed app icon view so macOS selects the best `.icns` mipmap and
/// applies high-quality downsampling on 1x displays instead of SwiftUI
/// linearly downscaling the 512pt bitmap.
struct NativeAppIcon: NSViewRepresentable {
    let image: NSImage
    var size: CGFloat = 20

    func makeNSView(context _: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.imageAlignment = .alignCenter
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateNSView(_ view: NSImageView, context _: Context) {
        if view.image !== image {
            view.image = image
        }
    }
}
