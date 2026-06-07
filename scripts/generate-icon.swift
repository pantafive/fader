// Renders the app icon: three vertical fader tracks with knobs on a dark
// rounded square. Regenerate with `make icon` after changing the drawing.
import AppKit

let canvas: CGFloat = 1024
let image = NSImage(size: NSSize(width: canvas, height: canvas))

image.lockFocus()

// Background: rounded square with the site's dark gradient, standard margin.
let margin: CGFloat = 100
let bgRect = NSRect(x: margin, y: margin, width: canvas - 2 * margin, height: canvas - 2 * margin)
let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: 185, yRadius: 185)
let gradient = NSGradient(
    starting: NSColor(red: 0.16, green: 0.18, blue: 0.24, alpha: 1),
    ending: NSColor(red: 0.05, green: 0.055, blue: 0.07, alpha: 1)
)!
gradient.draw(in: bgPath, angle: -90)

// Three fader tracks with knobs at different positions.
let trackWidth: CGFloat = 36
let trackHeight: CGFloat = 520
let trackY = (canvas - trackHeight) / 2
let knobRadius: CGFloat = 86
let positions: [(x: CGFloat, knob: CGFloat)] = [
    (canvas / 2 - 190, 0.30),
    (canvas / 2, 0.72),
    (canvas / 2 + 190, 0.48),
]

for fader in positions {
    let track = NSBezierPath(
        roundedRect: NSRect(x: fader.x - trackWidth / 2, y: trackY, width: trackWidth, height: trackHeight),
        xRadius: trackWidth / 2,
        yRadius: trackWidth / 2
    )
    NSColor(white: 1, alpha: 0.16).setFill()
    track.fill()

    let knobCenterY = trackY + trackHeight * fader.knob
    // Filled part of the track below the knob.
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

    let knobRect = NSRect(
        x: fader.x - knobRadius,
        y: knobCenterY - knobRadius,
        width: knobRadius * 2,
        height: knobRadius * 2
    )
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    NSColor.white.setFill()
    NSBezierPath(ovalIn: knobRect).fill()
}

image.unlockFocus()

// Write the master PNG; sips/iconutil produce the iconset from it.
guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:])
else {
    fatalError("Failed to render icon")
}

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png")
do {
    try png.write(to: output)
} catch {
    fatalError("Failed to write \(output.path): \(error)")
}

print("Wrote \(output.path)")
