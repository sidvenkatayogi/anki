// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
// PhotoPalaceView — a room photo with card "pins" laid over it at normalized
// positions. This is the 2-D representation of a palace: it drives placement
// (tap the photo to drop a pin) and snapshot study (tap a pin to answer
// "where is it?"), and it's the guaranteed fallback when live AR isn't
// available (Simulator, no camera, or a failed relocalize on device).

import SwiftUI

struct PhotoPalaceView: View {
    let image: UIImage
    let loci: [Locus]
    /// A locus to emphasize (the "what's here?" target); nil for none.
    var highlightedLocusID: UUID?
    /// Whether to show card labels next to pins (hidden during recall quizzing).
    var showLabels: Bool = true
    /// Tap on empty photo area → normalized point (place mode).
    var onPlace: ((PalacePoint) -> Void)?
    /// Tap on an existing pin → its locus id (locate mode / editing).
    var onSelectLocus: ((UUID) -> Void)?

    var body: some View {
        GeometryReader { geo in
            let rect = Self.fittedRect(imageSize: image.size, in: geo.size)
            ZStack(alignment: .topLeading) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { location in
                        guard let onPlace,
                              let p = Self.normalize(location, in: rect) else { return }
                        onPlace(p)
                    }

                ForEach(Array(loci.enumerated()), id: \.element.id) { index, locus in
                    PinMarker(
                        number: index + 1,
                        label: locus.label,
                        learned: locus.learned,
                        highlighted: locus.id == highlightedLocusID,
                        showLabel: showLabels
                    )
                    .position(
                        x: rect.minX + CGFloat(locus.point.x) * rect.width,
                        y: rect.minY + CGFloat(locus.point.y) * rect.height
                    )
                    .onTapGesture { onSelectLocus?(locus.id) }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    // MARK: - Geometry

    /// The rect an aspect-fit image occupies inside `container`.
    static func fittedRect(imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              container.width > 0, container.height > 0 else {
            return CGRect(origin: .zero, size: container)
        }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let w = imageSize.width * scale
        let h = imageSize.height * scale
        return CGRect(x: (container.width - w) / 2, y: (container.height - h) / 2, width: w, height: h)
    }

    /// Convert a tap in container coordinates to a normalized point within the
    /// image rect, or nil if the tap landed outside the image.
    static func normalize(_ location: CGPoint, in rect: CGRect) -> PalacePoint? {
        guard rect.width > 0, rect.height > 0 else { return nil }
        let nx = (location.x - rect.minX) / rect.width
        let ny = (location.y - rect.minY) / rect.height
        guard nx >= 0, nx <= 1, ny >= 0, ny <= 1 else { return nil }
        return PalacePoint(x: Float(nx), y: Float(ny))
    }
}

/// A single pin over the photo: numbered dot, optional label, highlight pulse.
private struct PinMarker: View {
    let number: Int
    let label: String
    let learned: Bool
    let highlighted: Bool
    let showLabel: Bool

    @State private var pulse = false

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle()
                    .fill(dotColor)
                    .frame(width: 30, height: 30)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
                    .shadow(radius: 2)
                Text("\(number)")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
            }
            .scaleEffect(highlighted && pulse ? 1.35 : 1.0)
            .overlay {
                if highlighted {
                    Circle()
                        .stroke(Color.yellow, lineWidth: 3)
                        .frame(width: 44, height: 44)
                        .scaleEffect(pulse ? 1.3 : 0.9)
                        .opacity(pulse ? 0.0 : 0.9)
                }
            }

            if showLabel && !label.isEmpty {
                Text(label)
                    .font(.caption2)
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }
        .onAppear {
            if highlighted {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
        }
    }

    private var dotColor: Color {
        if highlighted { return .orange }
        return learned ? .green : .accentColor
    }
}
