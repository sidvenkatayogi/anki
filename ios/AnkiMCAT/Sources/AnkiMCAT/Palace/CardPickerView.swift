// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
// CardPickerView — pick which existing MCAT card to place at a locus. Searches
// the collection with Anki's query syntax (debounced) and lazily renders a
// short label per visible row, so a large deck stays responsive.

import SwiftUI

struct CardPickerView: View {
    @Bindable var model: PalaceModel
    var onPick: (Int64) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [Int64] = []
    @State private var loading = false
    @State private var debounce: Task<Void, Never>?

    /// Cap displayed results so the picker stays light on huge decks.
    private let maxResults = 500

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Choose a card")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $query, prompt: "Search cards — e.g. tag:biochem, or free text")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
                .onChange(of: query) { _, _ in scheduleSearch() }
                .task { await runSearch() }
                .onDisappear { debounce?.cancel() }
        }
    }

    @ViewBuilder private var content: some View {
        if !model.ready {
            ContentUnavailableView(
                "Preparing cards…", systemImage: "hourglass",
                description: Text("The collection is still loading — try again in a moment."))
        } else if loading && results.isEmpty {
            ProgressView("Searching…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if results.isEmpty {
            ContentUnavailableView(
                "No cards", systemImage: "magnifyingglass",
                description: Text(query.isEmpty
                                  ? "No cards found in the collection."
                                  : "No cards match “\(query)”."))
        } else {
            List(results, id: \.self) { cid in
                Button {
                    onPick(cid)
                    dismiss()
                } label: {
                    CardPickerRow(model: model, cardID: cid)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func scheduleSearch() {
        debounce?.cancel()
        debounce = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            await runSearch()
        }
    }

    private func runSearch() async {
        loading = true
        let ids = await model.searchCardIDs(query)
        results = Array(ids.prefix(maxResults))
        loading = false
    }
}

/// A picker row that renders its card's label lazily when it scrolls into view.
private struct CardPickerRow: View {
    let model: PalaceModel
    let cardID: Int64
    @State private var label: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
            Text(label ?? "…")
                .foregroundStyle(label == nil ? .secondary : .primary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .task {
            if label == nil { label = await model.label(for: cardID) }
        }
    }
}
