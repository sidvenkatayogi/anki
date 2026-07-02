// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
// ReadView — the Read tab. States: not-configured (inline server URL/token
// form, mirroring the web round's decision that there's no separate settings
// dialog yet), loading (spinner), loaded (passage + quiz, submit-once,
// in-memory reveal), error (banner + Retry — never a blank/frozen screen).

import SwiftUI

struct ReadView: View {
    @Bindable var model: ReadModel

    @State private var formEndpoint = "http://localhost:8080/"
    @State private var formToken = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    switch model.phase {
                    case .notConfigured:
                        configCard
                    case .loading:
                        loadingBlock
                    case .loaded:
                        if let passage = model.passage {
                            passageCard(passage)
                            quizSection(passage)
                        }
                    case let .error(message):
                        errorBanner(message)
                    }
                }
                .padding(20)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Read")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task { await model.load() }
    }

    // MARK: - Not configured

    private var configCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "book.pages.fill")
                .font(.system(size: 44))
                .foregroundStyle(.indigo)
            Text("Set up the Read tab")
                .font(.title3.bold())
            Text("The Read tab pulls a short passage and quiz from your sync server. Enter your server URL and MCAT tools token to get started.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            field(icon: "server.rack", title: "Server URL") {
                TextField("http://localhost:8080/", text: $formEndpoint)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            field(icon: "key.fill", title: "MCAT tools token") {
                SecureField("token", text: $formToken)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Button(action: {
                model.saveConfig(endpoint: formEndpoint, token: formToken)
            }) {
                Text("Save & Load")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .disabled(formEndpoint.isEmpty || formToken.isEmpty)
        }
        .padding(20)
        .cardBackground()
    }

    // MARK: - Loading

    private var loadingBlock: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading a passage…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 60)
    }

    // MARK: - Error

    private func errorBanner(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text("Couldn't load a passage")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(action: { Task { await model.retry() } }) {
                Text("Retry")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(20)
        .cardBackground()
    }

    // MARK: - Loaded

    private func passageCard(_ passage: ReadModel.ReadPassage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(passage.source.capitalized)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.indigo.opacity(0.15), in: Capsule())
                    .foregroundStyle(.indigo)
                Spacer()
                Button(action: { Task { await model.reset() } }) {
                    Label("New passage", systemImage: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                }
            }
            Text(passage.title)
                .font(.title3.bold())
            if let url = URL(string: passage.url) {
                Link(destination: url) {
                    Label("Source", systemImage: "link")
                        .font(.caption)
                }
            }
            Text(passage.text)
                .font(.body)
                .lineSpacing(4)
        }
        .padding(20)
        .cardBackground()
    }

    private func quizSection(_ passage: ReadModel.ReadPassage) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Quiz")
                .font(.headline)

            ForEach(Array(passage.quiz.enumerated()), id: \.element.id) { index, question in
                questionCard(question, number: index + 1)
            }

            if !model.submitted {
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
    }

    private func questionCard(_ question: ReadModel.QuizQuestion, number: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(number). \(question.stem)")
                .font(.subheadline.weight(.semibold))

            VStack(spacing: 8) {
                ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                    optionRow(question: question, optionIndex: index, option: option)
                }
            }

            if model.submitted {
                let correct = model.isCorrect(question)
                VStack(alignment: .leading, spacing: 4) {
                    Label(correct ? "Correct" : "Incorrect",
                          systemImage: correct ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(correct ? .green : .red)
                    Text(question.explanation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
        }
        .padding(16)
        .cardBackground()
    }

    private func optionRow(
        question: ReadModel.QuizQuestion, optionIndex: Int, option: String
    ) -> some View {
        let isSelected = model.selections[question.id] == optionIndex
        let isAnswer = optionIndex == question.answerIndex
        let showReveal = model.submitted

        return Button(action: {
            model.select(optionIndex: optionIndex, forQuestion: question.id)
        }) {
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

    // MARK: - Shared bits

    private func field<Content: View>(
        icon: String, title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
                .padding(12)
                .background(Color(.tertiarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

private extension View {
    func cardBackground() -> some View {
        background(Color(.secondarySystemGroupedBackground),
                   in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
