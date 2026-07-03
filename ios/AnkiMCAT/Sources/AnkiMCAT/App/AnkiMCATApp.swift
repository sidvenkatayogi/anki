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
    @State private var sync: SyncModel
    @State private var practice: PracticeModel

    init() {
        let engine = AnkiEngine()
        _review = State(initialValue: ReviewModel(engine: engine))
        _palace = State(initialValue: PalaceModel(engine: engine))
        _sync = State(initialValue: SyncModel(engine: engine))
        _practice = State(initialValue: PracticeModel(engine: engine))
    }

    var body: some Scene {
        WindowGroup {
            RootView(review: review, palace: palace, sync: sync, practice: practice)
                .task {
                    // A sync that replaces the collection must rebuild the
                    // reviewer's queue and the palace's card cache.
                    sync.onCollectionChanged = { [review, palace] in
                        await review.reloadAfterSync()
                        palace.onEngineReady()
                    }
                    await review.start()
                    palace.onEngineReady()
                    // Launch-time palace sync reconciliation (AC2). Run in the
                    // background rather than awaited inline so a slow/absent
                    // sync server never delays startup; failures are silent
                    // (see PalaceSyncModel) and the next save or launch retries.
                    Task { await palace.pushAll() }
                    // Pull the latest on launch when signed in.
                    if sync.isLoggedIn {
                        await sync.sync()
                    }
                }
        }
    }
}

/// Four tabs on the shared engine: the classic review loop, the spatial memory
/// palace, practice questions, and the account/sync
/// screen — all backed by one opened collection.
struct RootView: View {
    @Bindable var review: ReviewModel
    let palace: PalaceModel
    let sync: SyncModel
    let practice: PracticeModel

    var body: some View {
        TabView {
            ReviewView(model: review)
                .tabItem { Label("Review", systemImage: "rectangle.on.rectangle") }

            PalaceListView(model: palace)
                .tabItem { Label("Palace", systemImage: "building.columns") }

            PracticeView(model: practice)
                .tabItem { Label("Practice", systemImage: "pencil.and.list.clipboard") }

            SyncView(model: sync)
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
        }
    }
}
