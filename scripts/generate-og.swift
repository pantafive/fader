// Renders the Open Graph preview card (1200x630) for link unfurls.
// Regenerate with `make og` after changing the drawing.
import AppKit

let width: CGFloat = 1200
let height: CGFloat = 630
let image = NSImage(size: NSSize(width: width, height: height))

image.lockFocus()

/// Background gradient matching the site.
let gradient = NSGradient(
    starting: NSColor(red: 0.10, green: 0.13, blue: 0.21, alpha: 1),
    ending: NSColor(red: 0.05, green: 0.055, blue: 0.07, alpha: 1)
)!
gradient.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: -75)

// Fader motif on the left.
let trackWidth: CGFloat = 26
let trackHeight: CGFloat = 360
let trackY = (height - trackHeight) / 2
let knobRadius: CGFloat = 56
let positions: [(x: CGFloat, knob: CGFloat)] = [
    (170, 0.30),
    (300, 0.72),
    (430, 0.48),
]

for fader in positions {
    let track = NSBezierPath(
        roundedRect: NSRect(x: fader.x - trackWidth / 2, y: trackY, width: trackWidth, height: trackHeight),
        xRadius: trackWidth / 2,
        yRadius: trackWidth / 2
    )
    NSColor(white: 1, alpha: 0.14).setFill()
    track.fill()

    let knobCenterY = trackY + trackHeight * fader.knob
    let fill = NSBezierPath(
        roundedRect: NSRect(
            x: fader.x - trackWidth / 2,
            y: trackY,
            width: trackWidth,
            height: knobCenterY - trackY
        ),
        xRadius: trackWidth / 2,
        yRadius: trackWidth / 2
    )
    NSColor(red: 0.36, green: 0.61, blue: 1.0, alpha: 1).setFill()
    fill.fill()

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
    shadow.shadowBlurRadius = 18
    shadow.shadowOffset = NSSize(width: 0, height: -6)
    shadow.set()
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(
        x: fader.x - knobRadius,
        y: knobCenterY - knobRadius,
        width: knobRadius * 2,
        height: knobRadius * 2
    )).fill()
    NSShadow().set()
}

/// Wordmark and tagline on the right.
let title = NSAttributedString(string: "Fader", attributes: [
    .font: NSFont.systemFont(ofSize: 110, weight: .bold),
    .foregroundColor: NSColor.white,
])
title.draw(at: NSPoint(x: 560, y: 330))

let tagline = NSAttributedString(
    string: "Per-app volume and one-click output\nswitching in your Mac menu bar.",
    attributes: [
        .font: NSFont.systemFont(ofSize: 38, weight: .regular),
        .foregroundColor: NSColor(white: 0.62, alpha: 1),
    ]
)
tagline.draw(at: NSPoint(x: 564, y: 200))

let badge = NSAttributedString(
    string: "free · open source · no telemetry",
    attributes: [
        .font: NSFont.systemFont(ofSize: 30, weight: .medium),
        .foregroundColor: NSColor(red: 0.36, green: 0.61, blue: 1.0, alpha: 1),
    ]
)
badge.draw(at: NSPoint(x: 564, y: 120))

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:])
else {
    fatalError("Failed to render OG image")
}

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "og.png")
do {
    try png.write(to: output)
} catch {
    fatalError("Failed to write \(output.path): \(error)")
}

print("Wrote \(output.path)")
