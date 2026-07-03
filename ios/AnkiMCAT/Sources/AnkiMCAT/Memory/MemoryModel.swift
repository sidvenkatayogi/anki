// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
// MemoryModel — drives the Memory tab, the iOS mirror of the desktop Topic
// Mastery dashboard (`ts/routes/mastery/+page.svelte`). It is the "Memory"
// leg of the three scores: the chance the student recalls a fact right now.
//
// It reads the per-topic mastery aggregate straight from the shared Rust engine
// (`engine.tagMastery`, the same RPC the desktop dashboard uses) so the number,
// its 90% confidence-interval range, coverage, "how sure", reasons,
// last-updated time, next-topic and give-up rule are identical across desktop
// and phone. Query params match the desktop page exactly (whole collection,
// group_depth 2, backend-default mastered threshold) so the two platforms
// produce the same Memory readiness band.

import Foundation
import SwiftUI

@MainActor
@Observable
final class MemoryModel {
    @ObservationIgnored private let engine: AnkiEngine

    /// The latest mastery snapshot, or nil until the first successful load.
    private(set) var data: Anki_Stats_TagMasteryResponse?
    /// True while a (re)load is in flight — drives the initial spinner only.
    private(set) var loading = false

    // Group by AAMC section. MileDown is single-rooted under "MileDown::", so
    // the sections live at depth 2; depth 1 would collapse everything into one
    // "MileDown" topic. Matches the desktop dashboard.
    private static let groupDepth: UInt32 = 2

    init(engine: AnkiEngine = AnkiEngine()) {
        self.engine = engine
    }

    /// Called once the shared collection is open (and again after a sync
    /// replaces it) to refresh the dashboard from the collection.
    func onEngineReady() {
        Task { [weak self] in await self?.reload() }
    }

    /// Re-pull the mastery aggregate. Offline-safe: a failing engine call (e.g.
    /// the collection isn't open yet) leaves the previous snapshot in place
    /// rather than blanking the screen.
    func reload() async {
        loading = data == nil
        defer { loading = false }
        // masteredThreshold 0 -> backend default (echoed back as thresholdUsed);
        // empty search -> whole collection, same as the desktop dashboard.
        if let response = try? await engine.tagMastery(
            groupDepth: Self.groupDepth, masteredThreshold: 0, search: "")
        {
            data = response
        }
    }
}
