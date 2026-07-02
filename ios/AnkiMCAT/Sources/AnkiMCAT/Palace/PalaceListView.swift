// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
// PalaceListView — the memory palace home: a list of captured places, a way to
// create new ones, and per-palace detail (add cards / study / manage spots).
// Navigation is a typed NavigationStack path so detail screens can push capture
// and study, and the "room full" prompt can spin up a fresh place inline.

import SwiftUI

/// Destinations reachable from the palace tab.
enum PalaceRoute: Hashable {
    case detail(UUID)
    case capture(UUID)
    case study(UUID)
}

struct PalaceListView: View {
    @Bindable var model: PalaceModel
    @State private var path: [PalaceRoute] = []
    @State private var showingNew = false

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if model.palaces.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("Memory Palace")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingNew = true
                    } label: {
                        Label("New place", systemImage: "plus")
                    }
                }
            }
            .navigationDestination(for: PalaceRoute.self) { route in
                switch route {
                case let .detail(id):
                    PalaceDetailView(model: model, palaceID: id, path: $path)
                case let .capture(id):
                    PalaceCaptureView(model: model, palaceID: id)
                case let .study(id):
                    PalaceStudyView(model: model, palaceID: id)
                }
            }
            .sheet(isPresented: $showingNew) {
                NewPalaceSheet { name, capacity in
                    let palace = model.createPalace(name: name, capacity: capacity)
                    showingNew = false
                    path.append(.capture(palace.id))
                }
            }
        }
    }

    private var list: some View {
        List {
            Section {
                ForEach(model.palaces) { palace in
                    NavigationLink(value: PalaceRoute.detail(palace.id)) {
                        PalaceRow(model: model, palace: palace)
                    }
                }
                .onDelete { offsets in
                    // Resolve to palace values first — deleting mutates the
                    // array, so indexing it again mid-loop deletes wrong rows.
                    let targets = offsets.map { model.palaces[$0] }
                    for palace in targets { model.delete(palace) }
                }
            } footer: {
                Text("Place cards at spots in rooms you know well, then recall them by location. When a room fills up, capture a new place.")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "building.columns")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("No palaces yet")
                .font(.title2.bold())
            Text("Capture a place you know well — your desk, kitchen, a room — and fill its spots with MCAT cards. You'll remember them by where they live.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                showingNew = true
            } label: {
                Label("Capture your first place", systemImage: "camera.viewfinder")
                    .padding(.vertical, 6)
                    .padding(.horizontal, 12)
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

/// One row in the palace list: thumbnail, name, spots used, learned count.
private struct PalaceRow: View {
    let model: PalaceModel
    let palace: Palace
    @State private var thumb: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 4) {
                Text(palace.name).font(.headline)
                Text(PalaceLogic.capacityStatus(palace))
                    .font(.caption)
                    .foregroundStyle(palace.isFull ? .orange : .secondary)
            }
            Spacer()
            if palace.hasWorldMap {
                Image(systemName: "arkit").foregroundStyle(.secondary)
            }
            if !palace.loci.isEmpty {
                ZStack {
                    ProgressRing(fraction: PalaceLogic.learnedFraction(palace), lineWidth: 3, tint: .green)
                        .frame(width: 32, height: 32)
                    Text("\(palace.learnedCount)")
                        .font(.caption2.bold().monospacedDigit())
                }
                .accessibilityLabel("\(palace.learnedCount) of \(palace.loci.count) recalled")
            }
        }
        .padding(.vertical, 4)
        // Re-run when the palace changes OR its photo is (re)saved.
        .task(id: "\(palace.id)-\(palace.photoVersion ?? 0)") {
            thumb = await Self.loadThumbnail(model: model, id: palace.id)
        }
    }

    @ViewBuilder private var thumbnail: some View {
        if let thumb {
            Image(uiImage: thumb)
                .resizable()
                .scaledToFill()
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        } else {
            RoundedRectangle(cornerRadius: 10)
                .fill(.quaternary)
                .frame(width: 52, height: 52)
                .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
        }
    }

    /// Load + downsample off the main thread so large room photos don't fully
    /// decode on the main thread on every row render.
    static func loadThumbnail(model: PalaceModel, id: UUID) async -> UIImage? {
        guard let data = model.photoData(forPalace: id) else { return nil }
        return await Task.detached(priority: .utility) {
            guard let src = UIImage(data: data) else { return nil }
            return src.preparingThumbnail(of: CGSize(width: 104, height: 104)) ?? src
        }.value
    }
}

/// Sheet to name a new palace and set how many spots it holds.
struct NewPalaceSheet: View {
    var onCreate: (String, Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var capacity = Palace.defaultCapacity

    var body: some View {
        NavigationStack {
            Form {
                Section("Place") {
                    TextField("e.g. My desk, Kitchen, Dorm room", text: $name)
                }
                Section {
                    Stepper("Spots: \(capacity)", value: $capacity, in: 1...20)
                } footer: {
                    Text("Memory palaces work best with a handful of vivid, well-separated spots. You can capture more places later.")
                }
            }
            .navigationTitle("New place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { onCreate(name, capacity) }
                }
            }
        }
    }
}

/// Wraps a locus id so it can drive a `.sheet(item:)`.
private struct LocusSelection: Identifiable { let id: UUID }

/// Per-palace detail: a journey map, stats, add cards / study, and per-spot
/// management (tap a spot to view its card, edit its mnemonic, or remove it).
struct PalaceDetailView: View {
    @Bindable var model: PalaceModel
    let palaceID: UUID
    @Binding var path: [PalaceRoute]

    @State private var photo: UIImage?
    @State private var selected: LocusSelection?
    @State private var renaming = false
    @State private var newName = ""

    private var palace: Palace? { model.palace(palaceID) }

    var body: some View {
        Group {
            if let palace {
                content(palace)
            } else {
                ContentUnavailableView("Palace not found", systemImage: "questionmark.folder")
            }
        }
        // Keyed on photoVersion so the map appears/refreshes when a photo is
        // added OR replaced after this screen first loaded (e.g. returning from
        // capture); this view stays in the nav stack, so it won't re-appear.
        .task(id: palace?.photoVersion ?? 0) {
            if let data = model.photoData(forPalace: palaceID) {
                photo = UIImage(data: data)
            } else {
                photo = nil
            }
        }
        .sheet(item: $selected) { sel in
            LocusDetailView(model: model, palaceID: palaceID, locusID: sel.id)
        }
        .alert("Rename place", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Save") { if let palace { model.rename(palace, to: newName) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func content(_ palace: Palace) -> some View {
        List {
            if let photo, !palace.loci.isEmpty {
                Section {
                    PhotoPalaceView(image: photo, loci: palace.loci,
                                    showLabels: false, showRoute: true)
                        .frame(height: 220)
                        .listRowInsets(EdgeInsets())
                } header: {
                    Text("Your journey")
                }
            }

            Section { statsRow(palace) }

            Section { actionButtons(palace) }

            if palace.isFull {
                Section { fullBanner }
            }

            Section("Spots (\(palace.loci.count)/\(palace.capacity))") {
                if palace.loci.isEmpty {
                    Text("No cards placed yet. Tap \"Add cards\" to start filling this place.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(palace.loci.enumerated()), id: \.element.id) { index, locus in
                        Button {
                            selected = LocusSelection(id: locus.id)
                        } label: {
                            LocusRow(number: index + 1, locus: locus)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { palace.loci[$0].id }
                        for id in ids { model.removeLocus(id, fromPalace: palace.id) }
                    }
                }
            }
        }
        .navigationTitle(palace.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        newName = palace.name
                        renaming = true
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    private func statsRow(_ palace: Palace) -> some View {
        HStack(spacing: 16) {
            StatRing(
                fraction: PalaceLogic.learnedFraction(palace),
                tint: .green,
                value: "\(Int((PalaceLogic.learnedFraction(palace) * 100).rounded()))%",
                caption: "recalled",
                size: 92)
            VStack(alignment: .leading, spacing: 6) {
                Label("\(palace.loci.count) spots placed", systemImage: "mappin")
                Label("\(palace.learnedCount) recalled", systemImage: "checkmark.circle")
                Label("\(palace.remainingSpace) spots free", systemImage: "plus.circle")
            }
            .font(.subheadline)
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private func actionButtons(_ palace: Palace) -> some View {
        Group {
            Button {
                path.append(.capture(palace.id))
            } label: {
                Label(palace.isFull ? "Room is full" : "Add cards", systemImage: "plus.viewfinder")
            }
            .disabled(palace.isFull)

            Button {
                path.append(.study(palace.id))
            } label: {
                Label("Study this palace", systemImage: "brain.head.profile")
            }
            .disabled(palace.loci.isEmpty)
        }
    }

    private var fullBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("This room is full", systemImage: "exclamationmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text("You've placed as many cards as this place holds. Capture a new place to keep going — a fresh room makes the new cards easier to recall.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button {
                let fresh = model.createPalace(name: "New place")
                path.append(.capture(fresh.id))
            } label: {
                Label("Capture a new place", systemImage: "camera.viewfinder")
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }
}

/// A single placed card in the detail list: spot number, label, mnemonic.
private struct LocusRow: View {
    let number: Int
    let locus: Locus

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(locus.learned ? Color.green : Color.accentColor)
                    .frame(width: 26, height: 26)
                Text("\(number)").font(.caption2.bold()).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(locus.label).lineLimit(2)
                if !locus.mnemonic.isEmpty {
                    Text(locus.mnemonic)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
    }
}
