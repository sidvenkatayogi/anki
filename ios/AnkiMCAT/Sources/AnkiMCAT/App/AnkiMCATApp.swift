// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
// App entry point. Creates ONE shared AnkiEngine and hands it to both the
// review loop (ReviewModel) and the memory palace (PalaceModel), so they share
// a single opened backend/collection (and the serialized-per-handle contract).
// ReviewModel.start() performs the open+import (C3); once it finishes we tell
// the palace the engine is ready so its card picker / study loop can query.

import SwiftUI

@main
struct AnkiMCATApp: App {
    @State private var review: ReviewModel
    @State private var palace: PalaceModel

    init() {
        let engine = AnkiEngine()
        _review = State(initialValue: ReviewModel(engine: engine))
        _palace = State(initialValue: PalaceModel(engine: engine))
    }

    var body: some Scene {
        WindowGroup {
            RootView(review: review, palace: palace)
                .task {
                    await review.start()
                    palace.onEngineReady()
                }
        }
    }
}

/// Two tabs on the shared engine: the classic review loop, and the spatial
/// memory palace built on top of the same cards.
struct RootView: View {
    @Bindable var review: ReviewModel
    let palace: PalaceModel

    var body: some View {
        TabView {
            ReviewView(model: review)
                .tabItem { Label("Review", systemImage: "rectangle.on.rectangle") }

            PalaceListView(model: palace)
                .tabItem { Label("Palace", systemImage: "building.columns") }
        }
    }
}
