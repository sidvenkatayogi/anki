// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
// PracticeView — the Practice tab. Bundled, fully-offline question bank, one
// question at a time (radio-row options, submit-once, reveal), plus
// Performance/Readiness cards below driven by MCATMetrics. Never fabricates
// numbers when `enough_data` is false -- shows the contract's gating rules
// as explicit "not enough data yet" placeholders instead.

import SwiftUI

struct PracticeView: View {
    @Bindable var model: PracticeModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if let loadError = model.loadError {
                        errorBanner(loadError)
                    } else if model.finished {
                        finishedCard
                    } else if let question = model.currentQuestion {
                        questionCard(question)
                    }

                    metricsSection
                }
                .padding(20)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Practice")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Error

    private func errorBanner(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .cardBackground()
    }

    // MARK: - Finished

    private var finishedCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text("You've gone through every question")
                .font(.title3.bold())
                .multilineTextAlignment(.center)
            Text("Your Performance and Readiness estimates below reflect everything you've answered so far.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(action: { model.restart() }) {
                Text("Start over")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(20)
        .cardBackground()
    }

    // MARK: - Question

    private func questionCard(_ question: SeedQuestion) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                categoryBadge(question.category)
                Spacer()
                Text("\(model.currentIndex + 1) / \(model.questions.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(question.stem)
                .font(.subheadline.weight(.semibold))

            VStack(spacing: 8) {
                ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                    optionRow(question: question, optionIndex: index, option: option)
                }
            }

            if model.submitted {
                VStack(alignment: .leading, spacing: 4) {
                    Label(model.isCorrect ? "Correct" : "Incorrect",
                          systemImage: model.isCorrect ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(model.isCorrect ? .green : .red)
                    Text(question.explanation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)

                Button(action: { model.next() }) {
                    Text("Next")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button(action: { model.submit() }) {
                    Text("Submit")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSubmit)
            }
        }
        .padding(16)
        .cardBackground()
    }

    private func optionRow(question: SeedQuestion, optionIndex: Int, option: String) -> some View {
        let isSelected = model.selectedOption == optionIndex
        let isAnswer = optionIndex == question.answerIndex
        let showReveal = model.submitted

        return Button(action: { model.select(optionIndex: optionIndex) }) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(rowTint(isSelected: isSelected, isAnswer: isAnswer, showReveal: showReveal))
                Text(option)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                Spacer()
            }
            .padding(12)
            .background(
                rowBackground(isSelected: isSelected, isAnswer: isAnswer, showReveal: showReveal),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .disabled(model.submitted)
    }

    private func rowTint(isSelected: Bool, isAnswer: Bool, showReveal: Bool) -> Color {
        if showReveal {
            if isAnswer { return .green }
            if isSelected { return .red }
            return .secondary
        }
        return isSelected ? .indigo : .secondary
    }

    private func rowBackground(isSelected: Bool, isAnswer: Bool, showReveal: Bool) -> Color {
        if showReveal {
            if isAnswer { return Color.green.opacity(0.15) }
            if isSelected { return Color.red.opacity(0.15) }
            return Color(.tertiarySystemBackground)
        }
        return isSelected ? Color.indigo.opacity(0.12) : Color(.tertiarySystemBackground)
    }

    private func categoryBadge(_ category: String) -> some View {
        Text(Self.categoryLabel(category))
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.indigo.opacity(0.15), in: Capsule())
            .foregroundStyle(.indigo)
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

    /// A probability in [0,1] as a whole-number percent.
    private static func pct(_ p: Double) -> Int {
        Int((p * 100).rounded())
    }

    // MARK: - Metrics section

    private var metricsSection: some View {
        VStack(spacing: 16) {
            performanceCard
            readinessCard
        }
    }

    private var performanceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Performance")
                .font(.headline)

            if let performance = model.performance, performance.overall.enoughData {
                HStack {
                    Text("Overall")
                        .font(.subheadline)
                    Spacer()
                    Text("\(Self.pct(performance.overall.p))%")
                        .font(.subheadline.weight(.semibold))
                }
                Text("Likely range: \(Self.pct(performance.overall.pLow))–\(Self.pct(performance.overall.pHigh))% · \(performance.overall.n) answered")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                notEnoughDataRow(label: "Overall")
            }

            Divider()

            ForEach(MCATCategory.allCases, id: \.self) { category in
                if let row = model.performance?.perCategory.first(where: { $0.category == category }),
                   row.enoughData {
                    HStack(alignment: .firstTextBaseline) {
                        Text(Self.categoryLabel(category))
                            .font(.subheadline)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            Text("\(Self.pct(row.p))%")
                                .font(.subheadline.weight(.semibold))
                            Text("\(Self.pct(row.pLow))–\(Self.pct(row.pHigh))%")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    notEnoughDataRow(label: Self.categoryLabel(category))
                }
            }
        }
        .padding(16)
        .cardBackground()
    }

    private var readinessCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Readiness")
                .font(.headline)

            if let readiness = model.readiness, readiness.enoughData, readiness.confidence != .low {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(readiness.scorePoint)")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                    Text("(\(readiness.scoreLow)–\(readiness.scoreHigh))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Label(readiness.confidence.rawValue.capitalized + " confidence",
                      systemImage: confidenceIcon(readiness.confidence))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(confidenceColor(readiness.confidence))
            } else {
                Text(readinessAbstainMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .cardBackground()
    }

    /// Shown in place of a Readiness score — either because there isn't enough
    /// data yet, or because the estimate's confidence is too low to report.
    private var readinessAbstainMessage: String {
        if let readiness = model.readiness, readiness.enoughData {
            return "Keep answering questions and reviewing cards — there isn't enough confidence in a score estimate yet."
        }
        let note = model.readiness?.note ?? ""
        return note.isEmpty
            ? "Answer more practice questions or review more cards to see a projected score."
            : note
    }

    private func notEnoughDataRow(label: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
            Spacer()
            Text("Not enough data")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func confidenceIcon(_ confidence: Confidence) -> String {
        switch confidence {
        case .high: return "checkmark.circle.fill"
        case .medium: return "minus.circle.fill"
        case .low: return "exclamationmark.circle.fill"
        }
    }

    private func confidenceColor(_ confidence: Confidence) -> Color {
        switch confidence {
        case .high: return .green
        case .medium: return .orange
        case .low: return .red
        }
    }
}

private extension View {
    func cardBackground() -> some View {
        background(Color(.secondarySystemGroupedBackground),
                   in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
