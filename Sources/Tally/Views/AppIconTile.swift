import SwiftUI

/// The flat Treeline app icon, drawn as vectors for in-window use —
/// same geometry as the icon artwork on its 1024 grid, so it matches
/// the .icns exactly and stays crisp at any size.
struct AppIconTile: View {
    var size: CGFloat

    private static let background = Color(red: 0x12 / 255, green: 0x33 / 255, blue: 0x28 / 255)
    private static let trunkGreen = Color(red: 0x5E / 255, green: 0x96 / 255, blue: 0x78 / 255)
    private static let branchMint = Color(red: 0xDF / 255, green: 0xF3 / 255, blue: 0xE8 / 255)

    var body: some View {
        Canvas { context, canvasSize in
            let s = canvasSize.width / 1024

            let tile = Path(
                roundedRect: CGRect(x: 0, y: 0, width: 1024 * s, height: 1024 * s),
                cornerRadius: 230 * s
            )
            context.fill(tile, with: .color(Self.background))

            var trunk = Path()
            trunk.move(to: CGPoint(x: 351 * s, y: 174 * s))
            trunk.addLine(to: CGPoint(x: 351 * s, y: 801 * s))
            context.stroke(
                trunk, with: .color(Self.trunkGreen),
                style: StrokeStyle(lineWidth: 54 * s, lineCap: .round)
            )
            for y in [174.0, 801.0] {
                let node = CGRect(x: (351 - 81) * s, y: (y - 81) * s, width: 162 * s, height: 162 * s)
                context.fill(Path(ellipseIn: node), with: .color(Self.trunkGreen))
            }

            var branch = Path()
            branch.move(to: CGPoint(x: 351 * s, y: 622 * s))
            branch.addCurve(
                to: CGPoint(x: 673 * s, y: 487 * s),
                control1: CGPoint(x: 351 * s, y: 532 * s),
                control2: CGPoint(x: 673 * s, y: 577 * s)
            )
            branch.addLine(to: CGPoint(x: 673 * s, y: 337 * s))
            context.stroke(
                branch, with: .color(Self.branchMint),
                style: StrokeStyle(lineWidth: 45 * s, lineCap: .round)
            )

            let ring = CGRect(x: (673 - 65) * s, y: (228 - 65) * s, width: 130 * s, height: 130 * s)
            context.stroke(Path(ellipseIn: ring), with: .color(Self.branchMint), lineWidth: 45 * s)
        }
        .frame(width: size, height: size)
    }
}
