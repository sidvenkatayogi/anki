// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
// PracticeView — the Practice tab. Bundled, fully-offline question bank, one
// question at a time (radio-row options, submit-once, reveal), plus
// Performance/Readiness cards below driven by MCATMetrics. Never fabricates
// numbers when `enough_data` is false — shows the contract's gating rules as
// explicit "not enough data yet" placeholders instead. Styled with the shared
// "Clinical Aurora" theme.

import SwiftUI

struct PracticeView: View {
    @Bindable var model: PracticeModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    if let loadError = model.loadError {
                        errorBanner(loadError)
                    } else if model.finished {
                        finishedCard
                    } else if let question = model.currentQuestion {
                        questionCard(question)
                    }
                }
                .padding(18)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .background(MCATScreenBackground())
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
        .frame(maxWidth: .infinity)
        .padding(20)
        .mcatCard()
    }

    // MARK: - Finished

    private var finishedCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 44))
                .foregroundStyle(MCATTheme.correct)
            Text("You've gone through every question")
                .font(.title3.bold())
                .multilineTextAlignment(.center)
            Text("See how you're doing in the Scores tab — it reflects everything you've answered so far.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(action: { Haptics.tap(); model.restart() }) {
                Text("Start over")
            }
            .buttonStyle(MCATPrimaryButtonStyle())
        }
        .padding(20)
        .mcatCard()
    }

    // MARK: - Question

    private func questionCard(_ question: SeedQuestion) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                MCATChip(text: Self.categoryLabel(question.category), tint: MCATTheme.amber)
                Spacer()
                Text("Q\(String(format: "%02d", model.currentIndex + 1)) / \(String(format: "%02d", model.questions.count))")
                    .font(.mono(12, .medium))
                    .foregroundStyle(MCATTheme.inkDim)
            }

            progressBar(
                fraction: model.questions.isEmpty
                    ? 0
                    : Double(model.currentIndex + 1) / Double(model.questions.count)
            )

            Text(question.stem)
                .font(.system(.subheadline).weight(.medium))
                .foregroundStyle(MCATTheme.ink)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 8) {
                ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                    optionRow(question: question, optionIndex: index, option: option)
                }
            }

            if model.submitted {
                VStack(alignment: .leading, spacing: 6) {
                    Label(model.isCorrect ? "Correct" : "Incorrect",
                          systemImage: model.isCorrect ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(model.isCorrect ? MCATTheme.correct : MCATTheme.incorrect)
                    Text(question.explanation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    (model.isCorrect ? MCATTheme.correct : MCATTheme.incorrect).opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )

                Button(action: { Haptics.tap(); model.next() }) {
                    Text("Next")
                }
                .buttonStyle(MCATPrimaryButtonStyle())
            } else {
                Button(action: {
                    model.submit()
                    if model.isCorrect { Haptics.success() } else { Haptics.warning() }
                }) {
                    Text("Submit")
                }
                .buttonStyle(MCATPrimaryButtonStyle())
                .disabled(!model.canSubmit)
                .opacity(model.canSubmit ? 1 : 0.5)
            }
        }
        .padding(18)
        .mcatCard()
    }

    private func optionRow(question: SeedQuestion, optionIndex: Int, option: String) -> some View {
        let isSelected = model.selectedOption == optionIndex
        let isAnswer = optionIndex == question.answerIndex
        let showReveal = model.submitted
        let tint = rowTint(isSelected: isSelected, isAnswer: isAnswer, showReveal: showReveal)

        return Button(action: {
            Haptics.selection()
            model.select(optionIndex: optionIndex)
        }) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: MCATTheme.cornerRadiusSmall)
                        .fill(markerFill(isSelected: isSelected, isAnswer: isAnswer, showReveal: showReveal))
                        .frame(width: 27, height: 27)
                    Text(String(Character(UnicodeScalar(UInt8(65 + optionIndex)))))
                        .font(.mono(13, .bold))
                        .foregroundStyle(markerText(isSelected: isSelected, isAnswer: isAnswer, showReveal: showReveal))
                }
                Text(option)
                    .font(.system(.subheadline))
                    .foregroundStyle(MCATTheme.ink)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if showReveal, isAnswer {
                    Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(MCATTheme.correct)
                } else if showReveal, isSelected {
                    Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(MCATTheme.incorrect)
                }
            }
            .padding(12)
            .background(
                rowBackground(isSelected: isSelected, isAnswer: isAnswer, showReveal: showReveal),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(tint.opacity(showReveal || isSelected ? 0.5 : 0.12), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(model.submitted)
    }

    private func rowTint(isSelected: Bool, isAnswer: Bool, showReveal: Bool) -> Color {
        if showReveal {
            if isAnswer { return MCATTheme.correct }
            if isSelected { return MCATTheme.incorrect }
            return MCATTheme.inkFaint
        }
        return isSelected ? MCATTheme.amber : MCATTheme.inkFaint
    }

    private func markerFill(isSelected: Bool, isAnswer: Bool, showReveal: Bool) -> Color {
        if showReveal {
            if isAnswer { return MCATTheme.correct }
            if isSelected { return MCATTheme.incorrect }
            return MCATTheme.well
        }
        return isSelected ? MCATTheme.amber : MCATTheme.well
    }

    private func markerText(isSelected: Bool, isAnswer: Bool, showReveal: Bool) -> Color {
        if showReveal {
            if isAnswer { return Color(hex: 0x06210D) }
            if isSelected { return Color(hex: 0x2A0705) }
            return MCATTheme.inkDim
        }
        return isSelected ? MCATTheme.amberInk : MCATTheme.inkDim
    }

    private func rowBackground(isSelected: Bool, isAnswer: Bool, showReveal: Bool) -> Color {
        if showReveal {
            if isAnswer { return MCATTheme.correct.opacity(0.12) }
            if isSelected { return MCATTheme.incorrect.opacity(0.12) }
            return MCATTheme.panel2
        }
        return isSelected ? MCATTheme.amber.opacity(0.12) : MCATTheme.panel2
    }

    private func progressBar(fraction: Double) -> some View {
        MCATNeutralBar(fraction: fraction, height: 6, tint: MCATTheme.amber)
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

}
