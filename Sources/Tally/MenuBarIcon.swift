import AppKit

/// The Treeline mark (trunk, two commit nodes, diverging branch, ring)
/// as a monochrome menu bar template image. Drawn in code because the
/// full app icon artwork doesn't survive at 18 pt — this is the same
/// geometry re-tuned for menu bar size, and `isTemplate` lets the
/// system tint it for light/dark/selected menu bars.
enum MenuBarIcon {
    static let image: NSImage = {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            draw(side: side)
            return true
        }
        image.isTemplate = true
        return image
    }()

    /// Draws on a top-left-origin `side` × `side` grid (tuned on 18 pt).
    static func draw(side: CGFloat) {
        let s = side / 18
        NSColor.black.setStroke()
        NSColor.black.setFill()

        // Trunk with a commit node at each end.
        let trunk = NSBezierPath()
        trunk.lineWidth = 1.7 * s
        trunk.lineCapStyle = .round
        trunk.move(to: NSPoint(x: 6.2 * s, y: 3.1 * s))
        trunk.line(to: NSPoint(x: 6.2 * s, y: 14.1 * s))
        trunk.stroke()
        node(x: 6.2 * s, y: 3.1 * s, radius: 1.8 * s).fill()
        node(x: 6.2 * s, y: 14.1 * s, radius: 1.8 * s).fill()

        // Branch diverging up-right toward the ring.
        let branch = NSBezierPath()
        branch.lineWidth = 1.5 * s
        branch.lineCapStyle = .round
        branch.move(to: NSPoint(x: 6.2 * s, y: 10.9 * s))
        branch.curve(
            to: NSPoint(x: 11.8 * s, y: 8.5 * s),
            controlPoint1: NSPoint(x: 6.2 * s, y: 9.3 * s),
            controlPoint2: NSPoint(x: 11.8 * s, y: 10.0 * s)
        )
        branch.line(to: NSPoint(x: 11.8 * s, y: 7.2 * s))
        branch.stroke()

        // Ring node at the branch tip — kept clear of the branch stroke
        // so the two stay separable when rendered in one color.
        let ring = NSBezierPath(
            ovalIn: NSRect(
                x: (11.8 - 1.3) * s, y: (3.8 - 1.3) * s,
                width: 2.6 * s, height: 2.6 * s
            )
        )
        ring.lineWidth = 1.3 * s
        ring.stroke()
    }

    private static func node(x: CGFloat, y: CGFloat, radius: CGFloat) -> NSBezierPath {
        NSBezierPath(ovalIn: NSRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
    }
}
