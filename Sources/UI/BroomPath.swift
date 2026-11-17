import CoreGraphics

/// The broom, as one path, used by the menu bar icon, the popover header and the app icon.
/// Drawn upright in a 100x100 box (y down), then tilted so it sweeps toward the bottom left.
/// Fill it even-odd: the bristle slits are holes.
enum BroomPath {
    static func path(in rect: CGRect, tilt: CGFloat = 0.62) -> CGPath {
        let p = CGMutablePath()
        // Handle
        p.addRoundedRect(in: CGRect(x: 46.5, y: 0, width: 7, height: 52), cornerWidth: 3.5, cornerHeight: 3.5)
        // Binding
        p.addRoundedRect(in: CGRect(x: 36, y: 50, width: 28, height: 11), cornerWidth: 3, cornerHeight: 3)
        // Bristles: a fan from the binding to a curved sweeping edge
        p.move(to: CGPoint(x: 37, y: 63))
        p.addLine(to: CGPoint(x: 63, y: 63))
        p.addLine(to: CGPoint(x: 79, y: 96))
        p.addQuadCurve(to: CGPoint(x: 21, y: 96), control: CGPoint(x: 50, y: 103))
        p.closeSubpath()
        // Slits between bristles (holes under even-odd fill)
        for (top, bottom) in [(44.0, 37.0), (50.0, 50.0), (56.0, 63.0)] {
            p.move(to: CGPoint(x: top - 1.2, y: 70))
            p.addLine(to: CGPoint(x: top + 1.2, y: 70))
            p.addLine(to: CGPoint(x: bottom + 1.6, y: 97))
            p.addLine(to: CGPoint(x: bottom - 1.6, y: 97))
            p.closeSubpath()
        }
        var t = CGAffineTransform.identity
            .translatedBy(x: rect.midX, y: rect.midY)
            .scaledBy(x: rect.width / 100 * 0.86, y: rect.height / 100 * 0.86)
            .rotated(by: tilt)
            .translatedBy(x: -50, y: -50)
        return p.copy(using: &t) ?? p
    }

    /// Little sparkle (four-point star) centered at `c`.
    static func sparkle(at c: CGPoint, size s: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: c.x, y: c.y - s))
        p.addQuadCurve(to: CGPoint(x: c.x + s, y: c.y), control: CGPoint(x: c.x + s * 0.18, y: c.y - s * 0.18))
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + s), control: CGPoint(x: c.x + s * 0.18, y: c.y + s * 0.18))
        p.addQuadCurve(to: CGPoint(x: c.x - s, y: c.y), control: CGPoint(x: c.x - s * 0.18, y: c.y + s * 0.18))
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - s), control: CGPoint(x: c.x - s * 0.18, y: c.y - s * 0.18))
        p.closeSubpath()
        return p
    }
}
