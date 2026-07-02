// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
// PalaceCaptureView — build a palace by placing cards at spots. On a real
// device it uses live AR (tap real surfaces, pins persist as world anchors); in
// the Simulator, on devices without AR, or as a fallback it uses a room photo
// (tap the image to drop pins). Placement flow is the same either way: pick a
// spot → choose a card → the card is pinned there and graded later through FSRS.
//
// When the room is full, placement is blocked and the user is guided to capture
// a new place.

import SwiftUI
import PhotosUI
import ARKit

struct PalaceCaptureView: View {
    @Bindable var model: PalaceModel
    let palaceID: UUID

    @Environment(\.dismiss) private var dismiss

    /// Prefer AR when the device supports it; the Simulator falls back to photo.
    @State private var useAR = ARWorldTrackingConfiguration.isSupported
    @State private var pending: PendingPlacement?
    @State private var showingPicker = false
    @State private var photoItem: PhotosPickerItem?
    @State private var statusText = ""
    @State private var saveToken = 0
    @State private var toast: String?

    private var palace: Palace? { model.palace(palaceID) }

    struct PendingPlacement {
        var transform: [Float]?
        var anchorID: String?
        var point: PalacePoint
    }

    var body: some View {
        Group {
            if let palace {
                content(palace)
            } else {
                ContentUnavailableView("Palace not found", systemImage: "questionmark.folder")
            }
        }
        .navigationTitle("Add cards")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingPicker) {
            CardPickerView(model: model) { cid in
                Task { await commit(cardID: cid) }
            }
        }
        .onChange(of: photoItem) { _, item in loadPhoto(item) }
    }

    @ViewBuilder
    private func content(_ palace: Palace) -> some View {
        ZStack {
            surface(palace)
            VStack {
                if !statusText.isEmpty && useAR {
                    banner(statusText)
                }
                Spacer()
                if palace.isFull {
                    fullOverlay
                } else {
                    capacityBar(palace)
                }
            }
            .padding()

            if let toast {
                Text(toast)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.opacity)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { surfaceToggle }
        }
    }

    // MARK: - Surface (AR or photo)

    @ViewBuilder
    private func surface(_ palace: Palace) -> some View {
        if useAR {
            ARPalaceView(
                mode: .capture,
                loci: palace.loci,
                saveToken: saveToken,
                onPlaced: { transform, anchorID, point in
                    guard let p = self.palace, !p.isFull else {
                        statusText = "Room full — capture a new place."
                        return
                    }
                    pending = PendingPlacement(transform: transform, anchorID: anchorID, point: point)
                    showingPicker = true
                },
                onStatus: { statusText = $0 },
                onWorldMapCaptured: { model.saveWorldMap($0, forPalace: palaceID) },
                onSnapshotCaptured: { model.savePhoto($0, forPalace: palaceID) }
            )
            .ignoresSafeArea(edges: .bottom)
        } else {
            photoSurface(palace)
        }
    }

    @ViewBuilder
    private func photoSurface(_ palace: Palace) -> some View {
        if let data = model.photoData(forPalace: palaceID), let ui = UIImage(data: data) {
            PhotoPalaceView(
                image: ui,
                loci: palace.loci,
                showLabels: true,
                showRoute: true,
                onPlace: { point in
                    guard !palace.isFull else { return }
                    pending = PendingPlacement(transform: nil, anchorID: nil, point: point)
                    showingPicker = true
                }
            )
        } else {
            photoPrompt
        }
    }

    private var photoPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 52))
                .foregroundStyle(.tint)
            Text("Add a photo of your place")
                .font(.title3.bold())
            Text("Choose a picture of the room you want to use. Then tap spots on it to place cards.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            PhotosPicker(selection: $photoItem, matching: .images) {
                Label("Choose photo", systemImage: "photo.on.rectangle")
                    .padding(.vertical, 6).padding(.horizontal, 12)
            }
            .buttonStyle(.borderedProminent)

            Button {
                if let img = PalaceSampleRoom.image() {
                    model.savePhoto(img, forPalace: palaceID)
                }
            } label: {
                Label("Use a sample room", systemImage: "square.grid.3x3.square")
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Overlays

    private func banner(_ text: String) -> some View {
        Text(text)
            .font(.callout.weight(.medium))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func capacityBar(_ palace: Palace) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text(PalaceLogic.capacityStatus(palace)).font(.subheadline.weight(.medium))
                Spacer()
                if !useAR && model.photoData(forPalace: palaceID) != nil {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label("Change photo", systemImage: "photo").font(.caption)
                    }
                }
            }
            ProgressView(value: Double(palace.loci.count), total: Double(max(palace.capacity, 1)))
            Text(placementHint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var placementHint: String {
        if useAR { return "Point at a surface and tap to place a card." }
        return "Tap a spot on the photo to place a card."
    }

    private var fullOverlay: some View {
        VStack(spacing: 10) {
            Label("This room is full", systemImage: "checkmark.seal.fill")
                .font(.headline).foregroundStyle(.orange)
            Text("Great — this place is packed. Go back and use “Capture a new place” to keep adding cards.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private var surfaceToggle: some View {
        if ARWorldTrackingConfiguration.isSupported {
            Picker("Surface", selection: $useAR) {
                Text("AR").tag(true)
                Text("Photo").tag(false)
            }
            .pickerStyle(.segmented)
            .frame(width: 130)
        }
    }

    // MARK: - Actions

    private func commit(cardID: Int64) async {
        guard let pending else { return }
        let ok = await model.addLocus(
            toPalace: palaceID,
            cardID: cardID,
            transform: pending.transform,
            anchorID: pending.anchorID,
            point: pending.point)
        self.pending = nil
        if ok {
            flash("Card placed")
            if useAR { saveToken &+= 1 }  // persist the updated world map
        } else {
            flash("Room is full")
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            if let data = try? await item.loadTransferable(type: Data.self) {
                model.savePhoto(data, forPalace: palaceID)
            }
        }
    }

    private func flash(_ text: String) {
        withAnimation { toast = text }
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            withAnimation { toast = nil }
        }
    }
}
