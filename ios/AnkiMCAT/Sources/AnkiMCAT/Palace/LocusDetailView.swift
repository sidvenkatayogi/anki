// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
// LocusDetailView — the sheet for a single placed spot. Shows the pinned card
// (question/answer), lets the user write the vivid mnemonic that ties the card
// to the location (the heart of the method of loci), toggle its recalled state,
// and remove it from the palace.

import SwiftUI

struct LocusDetailView: View {
    @Bindable var model: PalaceModel
    let palaceID: UUID
    let locusID: UUID

    @Environment(\.dismiss) private var dismiss
    @State private var rendered: RenderedCard?
    @State private var showingAnswer = false
    @State private var mnemonic = ""
    @State private var loaded = false

    private var locus: Locus? { model.palace(palaceID)?.loci.first { $0.id == locusID } }

    var body: some View {
        NavigationStack {
            Group {
                if let locus {
                    content(locus)
                } else {
                    ContentUnavailableView("Spot removed", systemImage: "mappin.slash")
                }
            }
            .navigationTitle("Spot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { save(); dismiss() }
                }
            }
        }
        .task { await load() }
        // Persist the mnemonic even when the sheet is swipe-dismissed (which
        // never runs the Done button). save() no-ops if nothing changed.
        .onDisappear { save() }
    }

    private func content(_ locus: Locus) -> some View {
        List {
            Section("Card") {
                if let rendered {
                    CardWebView(html: showingAnswer ? rendered.answer : rendered.question,
                                css: rendered.css)
                        .frame(height: 180)
                    Button(showingAnswer ? "Show question" : "Show answer") {
                        showingAnswer.toggle()
                    }
                    .font(.callout)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }

            Section {
                TextField("Picture the card vividly at this spot — the sillier, the more memorable",
                          text: $mnemonic, axis: .vertical)
                    .lineLimit(2...5)
            } header: {
                Text("Memory hook")
            } footer: {
                Text("A vivid, exaggerated image linking the card to this location is what makes loci stick.")
            }

            Section {
                HStack {
                    Label(locus.learned ? "Recalled" : "Not yet recalled",
                          systemImage: locus.learned ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(locus.learned ? .green : .secondary)
                    Spacer()
                    Button(locus.learned ? "Mark not recalled" : "Mark recalled") {
                        model.markLearned(!locus.learned, locusID: locusID, palaceID: palaceID)
                    }
                    .font(.caption)
                }
            }

            Section {
                Button(role: .destructive) {
                    save()
                    model.removeLocus(locusID, fromPalace: palaceID)
                    dismiss()
                } label: {
                    Label("Remove from palace", systemImage: "trash")
                }
            }
        }
    }

    private func load() async {
        guard !loaded, let locus else { return }
        loaded = true
        mnemonic = locus.mnemonic
        rendered = await model.renderCard(locus.cardID)
    }

    private func save() {
        // Only write if changed, to avoid churn.
        if mnemonic != (locus?.mnemonic ?? "") {
            model.setMnemonic(mnemonic, locusID: locusID, palaceID: palaceID)
        }
    }
}
