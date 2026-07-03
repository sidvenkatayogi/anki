// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
// MemoryView — the Memory tab: the iOS mirror of the desktop Topic Mastery
// dashboard. Shows the overall memory-recall readiness band (with its 90%
// confidence-interval range), coverage, "how sure", reasons, last-updated,
// next-topic, and a per-topic breakdown. Never fabricates a number: when there
// isn't enough graded history it shows the give-up message instead of a score.

import SwiftUI

struct MemoryView: View {
    @Bindable var model: MemoryModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if let data = model.data {
                        readinessCard(data)
                        topicsCard(data)
                    } else if model.loading {
                        ProgressView().padding(40)
                    } else {
                        Text("Study some cards to see your memory readiness.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(20)
                            .memoryCard()
                    }
                }
                .padding(20)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Memory")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await model.reload() }
        }
    }

    // MARK: - Readiness band

    private func readinessCard(_ data: Anki_Stats_TagMasteryResponse) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Memory readiness")
                .font(.headline)

            if data.enoughData, data.overallN > 0 {
                VStack(alignment: .center, spacing: 2) {
                    Text("\(Self.pct(data.overallMeanRecall))")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(.indigo)
                    Text("Likely range: \(Self.pct(data.overallCiLow)) – \(Self.pct(data.overallCiHigh))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("based on \(data.overallN) scored cards")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            } else {
                Text("Not enough data yet — keep reviewing to see your overall memory recall.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // Coverage / reasons / last-updated / next-topic are honest and
            // computable independently of the give-up rule, so they always
            // render. "How sure" is the exception: it describes confidence in
            // the readiness band, so it only shows once the band does.
            coverageRow(data)

            if data.enoughData, data.overallN > 0 {
                Text("How sure: \(Self.howSureLabel(data.howSure))")
                    .font(.subheadline.weight(.semibold))
            }

            Text("\(data.totalGradedReviews) reviews across \(data.topicsWithReviews) of \(data.topicsTotal) topics")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(Self.lastUpdatedText(data.lastUpdatedSecs))
                .font(.caption)
                .foregroundStyle(.secondary)

            if !data.nextTopic.isEmpty {
                Text("Study next: \(data.nextTopic)")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.indigo.opacity(0.12), in: Capsule())
            }
        }
        .padding(16)
        .memoryCard()
    }

    private func coverageRow(_ data: Anki_Stats_TagMasteryResponse) -> some View {
        let fraction = data.topicsTotal > 0
            ? Double(data.topicsCovered) / Double(data.topicsTotal)
            : 0
        return VStack(alignment: .leading, spacing: 4) {
            Text("Coverage: \(data.topicsCovered) / \(data.topicsTotal) topics studied")
                .font(.subheadline.weight(.semibold))
            ProgressView(value: fraction)
                .tint(.secondary)
        }
    }

    // MARK: - Per-topic breakdown

    private func topicsCard(_ data: Anki_Stats_TagMasteryResponse) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("By topic")
                .font(.headline)

            headerRow

            ForEach(data.groups, id: \.tag) { group in
                Divider()
                topicRow(group)
            }

            Text("Mastered = recall ≥ \(Self.pct(data.thresholdUsed))")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        .padding(16)
        .memoryCard()
    }

    private var headerRow: some View {
        HStack {
            Text("Topic").frame(maxWidth: .infinity, alignment: .leading)
            Text("Scored").frame(width: 56, alignment: .trailing)
            Text("Mast.").frame(width: 48, alignment: .trailing)
            Text("Recall").frame(width: 64, alignment: .trailing)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
    }

    private func topicRow(_ group: Anki_Stats_TagMasteryResponse.Group) -> some View {
        let hasState = group.cardsWithState > 0
        return HStack {
            Text(group.tag)
                .font(.footnote)
                .foregroundStyle(hasState ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("\(group.cardsWithState)/\(group.totalCards)")
                .frame(width: 56, alignment: .trailing)
            Text("\(group.masteredCards)")
                .frame(width: 48, alignment: .trailing)
            Text(hasState ? "\(Self.pct(group.averageRecall))" : "–")
                .frame(width: 64, alignment: .trailing)
        }
        .font(.footnote.monospacedDigit())
    }

    // MARK: - Formatting helpers

    /// A recall in [0,1] as a whole-number percent string, e.g. "83%".
    private static func pct(_ v: Double) -> String {
        "\(Int((v * 100).rounded()))%"
    }

    private static func howSureLabel(_ howSure: Anki_Stats_TagMasteryResponse.HowSure) -> String {
        switch howSure {
        case .high: return "high"
        case .medium: return "medium"
        case .low: return "low"
        default: return "not enough data"
        }
    }

    /// 0 is the backend's "no graded reviews yet" sentinel — never a date.
    private static func lastUpdatedText(_ secs: Int64) -> String {
        if secs == 0 {
            return "No reviews yet"
        }
        let date = Date(timeIntervalSince1970: TimeInterval(secs))
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Last updated: \(formatter.string(from: date))"
    }
}

private extension View {
    func memoryCard() -> some View {
        background(Color(.secondarySystemGroupedBackground),
                   in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
