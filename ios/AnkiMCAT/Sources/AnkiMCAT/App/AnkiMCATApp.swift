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
    @State private var settings: SettingsModel

    init() {
        let engine = AnkiEngine()
        let settings = SettingsModel()
        _review = State(initialValue: ReviewModel(engine: engine, settings: settings))
        _palace = State(initialValue: PalaceModel(engine: engine))
        _sync = State(initialValue: SyncModel(engine: engine))
        _practice = State(initialValue: PracticeModel(engine: engine))
        _settings = State(initialValue: settings)
    }

    var body: some Scene {
        WindowGroup {
            RootView(
                review: review,
                palace: palace,
                sync: sync,
                practice: practice,
                settings: settings
            )
                .task {
                    // A sync that replaces the collection must rebuild the
                    // reviewer's queue and re-read the palace + practice data
                    // (which now lives in the synced collection).
                    sync.onCollectionChanged = { [review, palace, practice] in
                        await review.reloadAfterSync()
                        palace.onEngineReady()
                        practice.onEngineReady()
                    }
                    await review.start()
                    // Seed (once) + load the practice bank, and reconcile the
                    // memory palaces with the collection. Both are idempotent
                    // and best-effort; onEngineReady kicks off background work
                    // rather than blocking startup.
                    palace.onEngineReady()
                    practice.onEngineReady()
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
    let settings: SettingsModel

    var body: some View {
        TabView {
            ReviewView(model: review, settings: settings)
                .tabItem { Label("Review", systemImage: "rectangle.on.rectangle") }

            PalaceListView(model: palace)
                .tabItem { Label("Palace", systemImage: "building.columns") }

            PracticeView(model: practice)
                .tabItem { Label("Practice", systemImage: "pencil.and.list.clipboard") }

            SyncView(model: sync)
                .tabItem { Label("Account", systemImage: "person.crop.circle") }

            SettingsView(model: settings)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}
