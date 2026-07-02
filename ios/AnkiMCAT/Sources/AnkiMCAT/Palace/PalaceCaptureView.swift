// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
// PalaceCaptureView — build a palace by placing cards at spots, card-first:
// the app shows you a readable, rendered card and you tap the spot it should
// live in. On a real device it uses live AR (tap real surfaces, pins persist as
// world anchors); in the Simulator / without AR / as a fallback it uses a room
// photo (tap the image). "Skip" fetches a different card. When the room is full
// (or every card is placed) the flow guides you onward.

import SwiftUI
import PhotosUI
import ARKit

struct PalaceCaptureView: View {
    @Bindable var model: PalaceModel
    let palaceID: UUID

    @Environment(\.dismiss) private var dismiss

    /// Prefer AR when the device supports it; the Simulator falls back to photo.
    @State private var useAR = ARWorldTrackingConfiguration.isSupported
    @State private var photoItem: PhotosPickerItem?
    @State private var statusText = ""
    @State private var saveToken = 0
    @State private var toast: String?

    // Card-first queue: cards not yet placed here, presented one at a time.
    @State private var queue: [Int64] = []
    @State private var qIndex = 0
    @State private var currentRendered: RenderedCard?
    @State private var showingAnswer = false
    @State private var loadingCards = true

    private var palace: Palace? { model.palace(palaceID) }
    private var currentCardID: Int64? { qIndex < queue.count ? queue[qIndex] : nil }
    private var hasPhoto: Bool { model.photoData(forPalace: palaceID) != nil }

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
        .toolbar { ToolbarItem(placement: .primaryAction) { surfaceToggle } }
        .onChange(of: photoItem) { _, item in loadPhoto(item) }
        // Load the card queue once the collection is open.
        .task(id: model.ready) { if model.ready { await loadCandidates() } }
    }

    @ViewBuilder
    private func content(_ palace: Palace) -> some View {
        if !useAR && !hasPhoto {
            photoPrompt
        } else {
            ZStack {
                surface(palace)
                VStack {
                    if useAR && !statusText.isEmpty { banner(statusText) }
                    Spacer()
                    bottomPanel(palace)
                }
                .padding()

                if let toast {
                    Text(toast)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .transition(.opacity)
                }
            }
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
                    Task { await placeCurrent(transform: transform, anchorID: anchorID, point: point) }
                },
                onStatus: { statusText = $0 },
                onWorldMapCaptured: { model.saveWorldMap($0, forPalace: palaceID) },
                onSnapshotCaptured: { model.savePhoto($0, forPalace: palaceID) })
                .ignoresSafeArea(edges: .bottom)
        } else if let data = model.photoData(forPalace: palaceID), let ui = UIImage(data: data) {
            PhotoPalaceView(
                image: ui,
                loci: palace.loci,
                showLabels: true,
                showRoute: true,
                onPlace: { point in
                    Task { await placeCurrent(transform: nil, anchorID: nil, point: point) }
                })
        } else {
            photoPrompt
        }
    }

    private var photoPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 52)).foregroundStyle(.tint)
            Text("Add a photo of your place").font(.title3.bold())
            Text("Choose a picture of the room you want to use, then place cards on it.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 32)
            PhotosPicker(selection: $photoItem, matching: .images) {
                Label("Choose photo", systemImage: "photo.on.rectangle")
                    .padding(.vertical, 6).padding(.horizontal, 12)
            }
            .buttonStyle(.borderedProminent)
            Button {
                if let img = PalaceSampleRoom.image() { model.savePhoto(img, forPalace: palaceID) }
            } label: {
                Label("Use a sample room", systemImage: "square.grid.3x3.square")
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Bottom panel (the card to place)

    @ViewBuilder
    private func bottomPanel(_ palace: Palace) -> some View {
        if palace.isFull {
            fullOverlay
        } else if !model.ready || loadingCards {
            panelBox { ProgressView("Loading cards…") }
        } else if currentCardID == nil {
            allPlacedPanel
        } else {
            cardPanel(palace)
        }
    }

    private func cardPanel(_ palace: Palace) -> some View {
        panelBox {
            VStack(spacing: 8) {
                HStack {
                    Text(PalaceLogic.capacityStatus(palace))
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    if !useAR {
                        PhotosPicker(selection: $photoItem, matching: .images) {
                            Label("Change photo", systemImage: "photo").font(.caption)
                        }
                    }
                }
                Text(useAR ? "Point at a surface and tap to place this card"
                           : "Tap the spot where this card should live")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Group {
                    if let r = currentRendered {
                        CardWebView(html: showingAnswer ? r.answer : r.question, css: r.css)
                    } else {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 150)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                HStack {
                    Button(showingAnswer ? "Show question" : "Show answer") {
                        showingAnswer.toggle()
                    }
                    .font(.callout)
                    Spacer()
                    Button { Task { await skip() } } label: {
                        Label("Skip", systemImage: "forward.end.fill")
                    }
                    .font(.callout)
                }
            }
        }
    }

    private var allPlacedPanel: some View {
        panelBox {
            VStack(spacing: 8) {
                Label("Every card placed", systemImage: "checkmark.seal.fill")
                    .font(.headline).foregroundStyle(.green)
                Text("Every card in your deck now lives somewhere in this palace.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
            }
        }
    }

    private var fullOverlay: some View {
        panelBox {
            VStack(spacing: 10) {
                Label("This room is full", systemImage: "checkmark.seal.fill")
                    .font(.headline).foregroundStyle(.orange)
                Text("Great — this place is packed. Go back and use “Capture a new place” to keep adding cards.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
            }
        }
    }

    private func panelBox<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func banner(_ text: String) -> some View {
        Text(text)
            .font(.callout.weight(.medium))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
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

    // MARK: - Card queue + placement

    private func loadCandidates() async {
        loadingCards = true
        queue = await model.unplacedCardIDs(forPalace: palaceID)
        qIndex = 0
        await loadCurrentRender()
        loadingCards = false
    }

    private func loadCurrentRender() async {
        currentRendered = nil
        guard let cid = currentCardID else { return }
        currentRendered = await model.renderCard(cid)
    }

    private func placeCurrent(transform: [Float]?, anchorID: String?, point: PalacePoint) async {
        guard let cid = currentCardID, let p = palace, !p.isFull else { return }
        let ok = await model.addLocus(
            toPalace: palaceID, cardID: cid,
            transform: transform, anchorID: anchorID, point: point)
        guard ok else { return }
        flash("Placed")
        if useAR { saveToken &+= 1 }  // persist the updated world map
        qIndex += 1
        showingAnswer = false
        await loadCurrentRender()
    }

    private func skip() async {
        qIndex += 1
        showingAnswer = false
        await loadCurrentRender()
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
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            withAnimation { toast = nil }
        }
    }
}
