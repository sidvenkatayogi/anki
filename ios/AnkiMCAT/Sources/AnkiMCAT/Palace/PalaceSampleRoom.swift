// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
// PalaceSampleRoom — a stylized "room" illustration drawn entirely in SwiftUI
// (no bundled image) and rendered to a UIImage on demand. It gives the photo
// path a zero-setup starting point ("Use a sample room"), makes the full
// place → study loop demoable and UI-testable in the Simulator, and gives the
// user recognizable landmarks (window, shelf, desk, plant, rug) to anchor
// cards to while they get the idea.

import SwiftUI

/// A flat-illustration room: warm wall, wood floor, window, bookshelf, desk +
/// lamp, framed picture, potted plant and a rug. Drawn with Canvas so it scales
/// crisply at any size.
struct DemoRoomView: View {
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            func rect(_ x: Double, _ y: Double, _ rw: Double, _ rh: Double) -> CGRect {
                CGRect(x: x * w, y: y * h, width: rw * w, height: rh * h)
            }
            func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * w, y: y * h) }

            // Wall
            ctx.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .linearGradient(Gradient(colors: [Color(red: 0.96, green: 0.93, blue: 0.86),
                                                              Color(red: 0.90, green: 0.85, blue: 0.76)]),
                                           startPoint: pt(0.5, 0), endPoint: pt(0.5, 0.7)))
            // Floor
            let floor = rect(0, 0.68, 1, 0.32)
            ctx.fill(Path(floor),
                     with: .linearGradient(Gradient(colors: [Color(red: 0.78, green: 0.60, blue: 0.40),
                                                             Color(red: 0.65, green: 0.47, blue: 0.30)]),
                                           startPoint: pt(0.5, 0.68), endPoint: pt(0.5, 1)))
            // Floor plank seams
            for i in 1..<7 {
                var p = Path()
                let y = 0.68 + Double(i) * 0.045
                p.move(to: pt(0, y)); p.addLine(to: pt(1, y))
                ctx.stroke(p, with: .color(.black.opacity(0.06)), lineWidth: 1.5)
            }

            // Rug
            let rug = rect(0.28, 0.80, 0.44, 0.15)
            ctx.fill(Path(roundedRect: rug, cornerRadius: rug.height / 2),
                     with: .color(Color(red: 0.30, green: 0.45, blue: 0.55).opacity(0.85)))
            ctx.stroke(Path(roundedRect: rug.insetBy(dx: rug.width * 0.06, dy: rug.height * 0.18),
                            cornerRadius: rug.height / 2),
                       with: .color(.white.opacity(0.5)), lineWidth: 3)

            // Window (top-left) — sky + frame + mullions
            let win = rect(0.07, 0.12, 0.26, 0.34)
            ctx.fill(Path(roundedRect: win.insetBy(dx: -6, dy: -6), cornerRadius: 10),
                     with: .color(Color(red: 0.55, green: 0.40, blue: 0.28)))  // frame
            ctx.fill(Path(win),
                     with: .linearGradient(Gradient(colors: [Color(red: 0.62, green: 0.82, blue: 0.96),
                                                             Color(red: 0.86, green: 0.94, blue: 0.99)]),
                                           startPoint: pt(0.2, 0.12), endPoint: pt(0.2, 0.46)))
            var mull = Path()
            mull.move(to: CGPoint(x: win.midX, y: win.minY)); mull.addLine(to: CGPoint(x: win.midX, y: win.maxY))
            mull.move(to: CGPoint(x: win.minX, y: win.midY)); mull.addLine(to: CGPoint(x: win.maxX, y: win.midY))
            ctx.stroke(mull, with: .color(Color(red: 0.55, green: 0.40, blue: 0.28)), lineWidth: 6)

            // Framed picture (top center-right)
            let frame = rect(0.44, 0.14, 0.14, 0.16)
            ctx.fill(Path(frame.insetBy(dx: -5, dy: -5)), with: .color(Color(red: 0.35, green: 0.28, blue: 0.22)))
            ctx.fill(Path(frame), with: .color(Color(red: 0.85, green: 0.80, blue: 0.70)))
            var hill = Path()
            hill.move(to: CGPoint(x: frame.minX, y: frame.maxY))
            hill.addQuadCurve(to: CGPoint(x: frame.midX, y: frame.midY),
                              control: CGPoint(x: frame.minX + frame.width * 0.25, y: frame.midY))
            hill.addQuadCurve(to: CGPoint(x: frame.maxX, y: frame.maxY),
                              control: CGPoint(x: frame.maxX - frame.width * 0.25, y: frame.midY))
            ctx.fill(hill, with: .color(Color(red: 0.45, green: 0.62, blue: 0.42)))

            // Bookshelf (right)
            let shelf = rect(0.70, 0.20, 0.24, 0.46)
            ctx.fill(Path(shelf), with: .color(Color(red: 0.52, green: 0.36, blue: 0.24)))
            let bookColors: [Color] = [.red, .orange, .green, .blue, .purple, .teal, .pink, .yellow]
            for row in 0..<3 {
                let shelfY = shelf.minY + shelf.height * (0.06 + Double(row) * 0.32)
                let shelfH = shelf.height * 0.26
                var bx = shelf.minX + shelf.width * 0.06
                var i = row * 3
                while bx < shelf.maxX - shelf.width * 0.10 {
                    let bw = shelf.width * [0.07, 0.09, 0.06, 0.08][i % 4]
                    let bh = shelfH * [0.9, 1.0, 0.8, 0.95][i % 4]
                    let b = CGRect(x: bx, y: shelfY + (shelfH - bh), width: bw, height: bh)
                    ctx.fill(Path(b), with: .color(bookColors[i % bookColors.count].opacity(0.9)))
                    bx += bw + shelf.width * 0.015
                    i += 1
                }
                var line = Path()
                let ly = shelfY + shelfH + shelf.height * 0.03
                line.move(to: CGPoint(x: shelf.minX, y: ly)); line.addLine(to: CGPoint(x: shelf.maxX, y: ly))
                ctx.stroke(line, with: .color(.black.opacity(0.25)), lineWidth: 3)
            }

            // Desk (center) + legs
            let deskTop = rect(0.34, 0.60, 0.30, 0.05)
            ctx.fill(Path(roundedRect: deskTop, cornerRadius: 4), with: .color(Color(red: 0.60, green: 0.42, blue: 0.28)))
            ctx.fill(Path(rect(0.36, 0.65, 0.02, 0.10)), with: .color(Color(red: 0.50, green: 0.34, blue: 0.22)))
            ctx.fill(Path(rect(0.60, 0.65, 0.02, 0.10)), with: .color(Color(red: 0.50, green: 0.34, blue: 0.22)))

            // Desk lamp
            let base = rect(0.37, 0.565, 0.04, 0.02)
            ctx.fill(Path(ellipseIn: base), with: .color(Color(red: 0.20, green: 0.22, blue: 0.26)))
            var arm = Path()
            arm.move(to: pt(0.39, 0.575)); arm.addLine(to: pt(0.40, 0.50)); arm.addLine(to: pt(0.435, 0.505))
            ctx.stroke(arm, with: .color(Color(red: 0.20, green: 0.22, blue: 0.26)), lineWidth: 4)
            ctx.fill(Path(ellipseIn: rect(0.425, 0.485, 0.035, 0.03)), with: .color(Color(red: 0.95, green: 0.80, blue: 0.35)))

            // Potted plant (bottom-left)
            let pot = rect(0.14, 0.66, 0.09, 0.10)
            var potShape = Path()
            potShape.move(to: CGPoint(x: pot.minX, y: pot.minY))
            potShape.addLine(to: CGPoint(x: pot.maxX, y: pot.minY))
            potShape.addLine(to: CGPoint(x: pot.maxX - pot.width * 0.15, y: pot.maxY))
            potShape.addLine(to: CGPoint(x: pot.minX + pot.width * 0.15, y: pot.maxY))
            potShape.closeSubpath()
            ctx.fill(potShape, with: .color(Color(red: 0.80, green: 0.45, blue: 0.35)))
            for (dx, dy, r) in [(0.0, -0.02, 0.05), (-0.03, 0.0, 0.04), (0.03, 0.0, 0.04)] {
                ctx.fill(Path(ellipseIn: rect(0.185 + dx - r / 2, 0.60 + dy - r / 2, r, r * 1.2)),
                         with: .color(Color(red: 0.30, green: 0.55, blue: 0.35)))
            }
        }
        .background(Color(red: 0.96, green: 0.93, blue: 0.86))
    }
}

@MainActor
enum PalaceSampleRoom {
    /// Render the demo room to a UIImage. Cached after first use.
    private static var cached: UIImage?

    static func image(size: CGSize = CGSize(width: 1200, height: 900)) -> UIImage? {
        if let cached { return cached }
        let renderer = ImageRenderer(content: DemoRoomView().frame(width: size.width, height: size.height))
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(size)
        let image = renderer.uiImage
        cached = image
        return image
    }
}
