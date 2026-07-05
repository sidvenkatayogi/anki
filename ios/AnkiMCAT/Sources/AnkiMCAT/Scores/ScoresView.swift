// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
// ScoresView — the unified "Scores" tab: all three honest scores in one place,
// mirroring the desktop `mastery` (Scores) dashboard.
//
//   1. Memory      — chance of recalling a fact now (neutral recall gauge +
//                    coverage + per-topic breakdown, from `MemoryModel`).
//   2. Performance — chance of a new exam-style question right (brand gauge +
//                    per-section bars, from `PracticeModel`).
//   3. Readiness   — projected 472–528 scaled score (aurora hero, from
//                    `PracticeModel`).
//
// The three are deliberately never blended into one number. Answering happens
// on the Practice tab; because both models are shared, the metrics here update
// live. Pull-to-refresh re-pulls memory + recomputes the practice metrics.
//
// HONESTY RULE: the Memory recall gauge and per-topic bars stay NEUTRAL
// (monochrome) — recall is not readiness. Semantic colour is for real
// correctness only; Performance/Readiness use the brand hue (they are scored).

import SwiftUI

struct ScoresView: View {
    @Bindable var memory: MemoryModel
    @Bindable var practice: PracticeModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if let data = memory.data {
                        memoryCard(data)
                        performanceCard
                        readinessCard
                        topicsCard(data)
                    } else if memory.loading {
                        ProgressView().padding(40)
                    } else {
                        emptyCard
                        performanceCard
                        readinessCard
                    }
                }
                .padding(18)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .background(MCATScreenBackground())
            .navigationTitle("Scores")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable {
                await memory.reload()
                await practice.recomputeMetrics()
            }
        }
    }

    private var emptyCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 40))
                .foregroundStyle(MCATTheme.amber)
            Text("Study some cards to see your memory readiness.")
                .font(.mono(14))
                .foregroundStyle(MCATTheme.inkDim)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .mcatCard()
    }

    // MARK: - 1. Memory

    private func memoryCard(_ data: Anki_Stats_TagMasteryResponse) -> some View {
        VStack(spacing: 14) {
            sectionHeader("Memory readiness", icon: "waveform.path.ecg")

            if data.enoughData, data.overallN > 0 {
                MCATGauge(
                    fraction: data.overallMeanRecall,
                    value: Self.pct(data.overallMeanRecall),
                    label: "recall",
                    style: .neutral,
                    size: 156,
                    lineWidth: 15
                )
                VStack(spacing: 3) {
                    Text("Likely \(Self.pct(data.overallCiLow)) – \(Self.pct(data.overallCiHigh))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("based on \(data.overallN) scored cards")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("How sure: \(Self.howSureLabel(data.howSure))")
                        .font(.subheadline.weight(.semibold))
                        .padding(.top, 2)
                }
            } else {
                MCATGauge(
                    fraction: 0,
                    value: "–",
                    label: "recall",
                    style: .neutral,
                    size: 156,
                    lineWidth: 15
                )
                .opacity(0.55)
                Text("Not enough data yet — keep reviewing to see your overall memory recall.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Divider()

            coverageRow(data)

            VStack(spacing: 3) {
                Text("\(data.totalGradedReviews) reviews across \(data.topicsWithReviews) of \(data.topicsTotal) topics")
                Text(Self.lastUpdatedText(data.lastUpdatedSecs))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)

            if !data.nextTopic.isEmpty {
                HStack {
                    MCATChip(
                        text: "Study next: \(data.nextTopic)",
                        systemImage: "arrow.forward.circle.fill",
                        tint: MCATTheme.amberDeep
                    )
                    Spacer()
                }
            }
        }
        .padding(18)
        .mcatCard()
    }

    private func coverageRow(_ data: Anki_Stats_TagMasteryResponse) -> some View {
        let fraction = data.topicsTotal > 0
            ? Double(data.topicsCovered) / Double(data.topicsTotal)
            : 0
        return VStack(alignment: .leading, spacing: 6) {
            Text("Coverage: \(data.topicsCovered) / \(data.topicsTotal) topics studied")
                .font(.subheadline.weight(.semibold))
            neutralBar(fraction: fraction, height: 7)
        }
    }

    private func topicsCard(_ data: Anki_Stats_TagMasteryResponse) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("By topic", icon: "list.bullet.rectangle")

            ForEach(Array(data.groups.enumerated()), id: \.element.tag) { index, group in
                if index > 0 { Divider() }
                topicRow(group)
            }

            Text("Mastered = recall ≥ \(Self.pct(data.thresholdUsed))")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
        .padding(18)
        .mcatCard()
    }

    private func topicRow(_ group: Anki_Stats_TagMasteryResponse.Group) -> some View {
        let hasState = group.cardsWithState > 0
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(group.tag)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(hasState ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(hasState ? Self.pct(group.averageRecall) : "–")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(hasState ? .primary : .secondary)
            }
            if hasState {
                neutralBar(fraction: group.averageRecall, height: 5)
            }
            Text("\(group.cardsWithState)/\(group.totalCards) scored · \(group.masteredCards) mastered")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }

    // MARK: - 2. Performance

    private var performanceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Performance", icon: "target")

            if let performance = practice.performance, performance.overall.enoughData {
                HStack(spacing: 16) {
                    MCATGauge(
                        fraction: performance.overall.p,
                        value: Self.pct(performance.overall.p),
                        label: "correct",
                        style: .brand,
                        size: 116,
                        lineWidth: 12
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Chance of a new question right")
                            .font(.subheadline.weight(.semibold))
                        Text("Likely \(Self.pct(performance.overall.pLow))–\(Self.pct(performance.overall.pHigh))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("based on \(performance.overall.n) answers")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            } else {
                notEnoughDataRow(label: "Overall", detail: "answer 5 to unlock")
            }

            Divider()

            ForEach(MCATCategory.allCases, id: \.self) { category in
                if let row = practice.performance?.perCategory.first(where: { $0.category == category }),
                   row.enoughData {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(Self.categoryLabel(category))
                                .font(.subheadline)
                            Spacer()
                            Text(Self.pct(row.p))
                                .font(.subheadline.weight(.semibold).monospacedDigit())
                            Text("(\(Self.pct(row.pLow))–\(Self.pct(row.pHigh)))")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        brandBar(fraction: row.p)
                    }
                    .padding(.vertical, 2)
                } else {
                    notEnoughDataRow(label: Self.categoryLabel(category), detail: "not enough data")
                }
            }
        }
        .padding(18)
        .mcatCard()
    }

    // MARK: - 3. Readiness

    private var readinessCard: some View {
        Group {
            if let readiness = practice.readiness, readiness.enoughData, readiness.confidence != .low {
                VStack(alignment: .leading, spacing: 12) {
                    MCATSectionHeader("Readiness")
                    Text("PROJECTED SCALED SCORE")
                        .font(.mono(11, .semibold))
                        .kerning(1.4)
                        .foregroundStyle(MCATTheme.inkDim)
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("\(readiness.scorePoint)")
                            .font(.mono(56, .bold))
                            .foregroundStyle(MCATTheme.amber)
                            .shadow(color: MCATTheme.amber.opacity(0.35), radius: 16)
                        Text("likely \(readiness.scoreLow)–\(readiness.scoreHigh)")
                            .font(.mono(14))
                            .foregroundStyle(MCATTheme.inkDim)
                    }
                    scoreScale(readiness)
                    HStack(spacing: 6) {
                        Image(systemName: confidenceIcon(readiness.confidence))
                        Text(readiness.confidence.rawValue.uppercased() + " CONFIDENCE")
                    }
                    .font(.mono(11, .semibold))
                    .kerning(0.8)
                    .foregroundStyle(readiness.confidence == .high ? MCATTheme.correct : MCATTheme.amber)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .overlay(
                        RoundedRectangle(cornerRadius: MCATTheme.cornerRadiusSmall)
                            .strokeBorder((readiness.confidence == .high ? MCATTheme.correct : MCATTheme.amber).opacity(0.42), lineWidth: 1)
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .mcatHero()
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    sectionHeader("Readiness", icon: "flag.checkered")
                    Text(readinessAbstainMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .mcatCard()
            }
        }
    }

    /// A 472–528 track with the likely range shaded and the point marked.
    private func scoreScale(_ readiness: Readiness) -> some View {
        let lo = Double(readiness.scoreLow - 472) / 56
        let hi = Double(readiness.scoreHigh - 472) / 56
        let pt = Double(readiness.scorePoint - 472) / 56
        return VStack(spacing: 4) {
            MCATScale(lo: lo, hi: hi, pt: pt, accent: MCATTheme.amber)
            HStack {
                Text("472")
                Spacer()
                Text("500").foregroundStyle(MCATTheme.inkFaint)
                Spacer()
                Text("528")
            }
            .font(.mono(11))
            .foregroundStyle(MCATTheme.inkDim)
        }
        .padding(.top, 2)
    }

    private var readinessAbstainMessage: String {
        if let readiness = practice.readiness, readiness.enoughData {
            return "Keep answering questions and reviewing cards — there isn't enough confidence in a score estimate yet."
        }
        let note = practice.readiness?.note ?? ""
        return note.isEmpty
            ? "Answer more practice questions or review more cards to see a projected score."
            : note
    }

    // MARK: - Shared bits

    private func notEnoughDataRow(label: String, detail: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
            Spacer()
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // Honest neutral (steel) magnitude — for recall.
    private func neutralBar(fraction: Double, height: CGFloat) -> some View {
        MCATNeutralBar(fraction: fraction, height: height, tint: MCATTheme.steel)
    }

    // Amber — legitimate for the scored Performance metric.
    private func brandBar(fraction: Double) -> some View {
        MCATNeutralBar(fraction: fraction, height: 6, tint: MCATTheme.amber)
    }

    private func sectionHeader(_ title: String, icon: String) -> some View {
        MCATSectionHeader(title, icon: icon)
    }

    private func confidenceIcon(_ confidence: Confidence) -> String {
        switch confidence {
        case .high: return "checkmark.circle.fill"
        case .medium: return "minus.circle.fill"
        case .low: return "exclamationmark.circle.fill"
        }
    }

    // MARK: - Formatting helpers

    /// A value in [0,1] as a whole-number percent string, e.g. "83%".
    private static func pct(_ v: Double) -> String {
        "\(Int((v * 100).rounded()))%"
    }

    private static func categoryLabel(_ raw: String) -> String {
        switch raw {
        case "bio_biochem": return "Bio/Biochem"
        case "chem_phys": return "Chem/Phys"
        case "psych_soc": return "Psych/Soc"
        case "cars": return "CARS"
        default: return raw
        }
    }

    private static func categoryLabel(_ category: MCATCategory) -> String {
        categoryLabel(category.rawValue)
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
