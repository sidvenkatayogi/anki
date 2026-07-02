// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
// PalaceVisuals — small reusable visualization components for the memory
// palace: a circular progress ring and a labelled stat ring. The "journey"
// route visualization lives in PhotoPalaceView (it needs the photo geometry)
// and is reused for the detail map and the study recap.

import SwiftUI

/// A thin circular progress ring (fraction 0...1), animated on change.
struct ProgressRing: View {
    var fraction: Double
    var lineWidth: CGFloat = 6
    var tint: Color = .green

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0, min(1, fraction)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.6), value: fraction)
        }
    }
}

/// A large ring with a big centered value and a caption — used on the study
/// recap and the palace detail header.
struct StatRing: View {
    var fraction: Double
    var tint: Color
    var value: String
    var caption: String
    var size: CGFloat = 140

    var body: some View {
        ZStack {
            ProgressRing(fraction: fraction, lineWidth: 12, tint: tint)
            VStack(spacing: 2) {
                Text(value).font(.system(size: size * 0.26, weight: .bold).monospacedDigit())
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }
}
