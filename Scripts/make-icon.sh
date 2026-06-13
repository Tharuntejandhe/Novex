#!/usr/bin/env bash
# Generate Novex's app icon from scratch — zero cost, no designer, no assets.
# Renders a gradient "squircle" with a sparkle glyph at 1024px (CoreGraphics),
# then expands to a full .icns via sips + iconutil.
#
# Output: Resources/AppIcon.icns  (make-app.sh copies it into the bundle).
# Run:    Scripts/make-icon.sh

set -euo pipefail
cd "$(dirname "$0")/.."

OUT_DIR="Resources"
ICONSET="$(mktemp -d)/AppIcon.iconset"
MASTER="$(mktemp -d)/novex-1024.png"
mkdir -p "${OUT_DIR}" "${ICONSET}"

echo "==> rendering 1024px master with CoreGraphics"
RENDER_SWIFT="$(mktemp -d)/render.swift"
cat > "${RENDER_SWIFT}" <<'SWIFT'
import AppKit

let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError("no ctx") }

// Apple icon grid: rounded-rect content inset from the 1024 canvas.
let inset = 100.0
let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let radius = (size - inset * 2) * 0.2237   // Big Sur continuous-corner ratio

let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

// Soft drop shadow under the squircle.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 44,
              color: NSColor.black.withAlphaComponent(0.28).cgColor)
NSColor.black.setFill()
path.fill()
ctx.restoreGState()

// Gradient fill (indigo → violet → blue) — the "novex".
path.addClip()
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.36, green: 0.24, blue: 0.86, alpha: 1.0),
    NSColor(calibratedRed: 0.49, green: 0.30, blue: 0.93, alpha: 1.0),
    NSColor(calibratedRed: 0.27, green: 0.46, blue: 0.96, alpha: 1.0),
])
gradient?.draw(in: rect, angle: -60)

// Subtle top highlight for depth.
let highlight = NSGradient(colors: [
    NSColor.white.withAlphaComponent(0.22),
    NSColor.white.withAlphaComponent(0.0),
])
highlight?.draw(in: rect, angle: -90)

// Centered sparkle glyph.
if let symbol = NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil) {
    let config = NSImage.SymbolConfiguration(pointSize: 560, weight: .semibold)
    if let glyph = symbol.withSymbolConfiguration(config) {
        let g = glyph.size
        let scale = min(540.0 / g.width, 540.0 / g.height)
        let drawSize = NSSize(width: g.width * scale, height: g.height * scale)
        let origin = NSPoint(x: (size - drawSize.width) / 2, y: (size - drawSize.height) / 2)
        NSColor.white.withAlphaComponent(0.96).set()
        glyph.draw(in: NSRect(origin: origin, size: drawSize),
                   from: .zero, operation: .sourceOver, fraction: 1.0)
        // Tint the template glyph white.
        NSRect(origin: origin, size: drawSize).clip()
        NSColor.white.withAlphaComponent(0.96).set()
        NSRect(origin: origin, size: drawSize).fill(using: .sourceAtop)
    }
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("encode failed")
}
let outPath = CommandLine.arguments[1]
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
SWIFT

swift "${RENDER_SWIFT}" "${MASTER}"

echo "==> expanding to iconset"
gen() { sips -z "$2" "$2" "${MASTER}" --out "${ICONSET}/$1" >/dev/null; }
gen icon_16x16.png        16
gen icon_16x16@2x.png     32
gen icon_32x32.png        32
gen icon_32x32@2x.png     64
gen icon_128x128.png      128
gen icon_128x128@2x.png   256
gen icon_256x256.png      256
gen icon_256x256@2x.png   512
gen icon_512x512.png      512
gen icon_512x512@2x.png   1024

echo "==> building ${OUT_DIR}/AppIcon.icns"
iconutil -c icns "${ICONSET}" -o "${OUT_DIR}/AppIcon.icns"

echo ""
echo "Done: ${OUT_DIR}/AppIcon.icns"
echo "make-app.sh will bundle it automatically on the next build."
