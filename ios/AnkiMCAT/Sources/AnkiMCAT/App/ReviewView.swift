// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
// ReviewView — the single review screen. Renders the current card in an elevated
// surface, a Show Answer button, then Again/Hard/Good/Easy grading buttons that
// round-trip through the shared Rust scheduler (C4). Styled with the shared
// "Clinical Aurora" theme (see Theme.swift) and tactile haptics.

import SwiftUI

struct ReviewView: View {
    // Received from the app; owns backend state and drives the loop.
    @Bindable var model: ReviewModel
    // Per-device settings; decides whether the voice + AI flow is shown.
    var settings: SettingsModel
    // Gates the "Didn't Learn" confirmation — the action is topic-level and
    // suspends every card in the topic, so we confirm before running it.
    @State private var confirmDidntLearn = false

    var body: some View {
        NavigationStack {
            Group {
                switch model.phase {
                case .launching:
                    launching
                case .reviewing:
                    reviewing
                case .finished:
                    finished
                case let .failed(message):
                    failure(message)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(MCATScreenBackground())
            .navigationTitle("Review")
        }
    }

    // MARK: - Phases

    private var launching: some View {
        VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: MCATTheme.cornerRadius, style: .continuous)
                    .fill(MCATTheme.amber)
                    .frame(width: 84, height: 84)
                    .shadow(color: MCATTheme.amber.opacity(0.4), radius: 18, y: 6)
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(MCATTheme.amberInk)
            }
            ProgressView().tint(MCATTheme.amber)
            Text(model.statusLine)
                .font(.mono(13))
                .foregroundStyle(MCATTheme.inkDim)
        }
        .accessibilityElement(children: .combine)
    }

    private var reviewing: some View {
        VStack(spacing: 14) {
            queueBar

            CardWebView(
                html: model.showingAnswer ? model.answerHTML : model.questionHTML,
                css: model.cardCSS
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(MCATTheme.panel)
            .clipShape(RoundedRectangle(cornerRadius: MCATTheme.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: MCATTheme.cornerRadius, style: .continuous)
                    .strokeBorder(MCATTheme.line, lineWidth: 1)
            )

            controls

            didntLearnBar
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .confirmationDialog(
            "Mark this topic as not yet learned?",
            isPresented: $confirmDidntLearn,
            titleVisibility: .visible
        ) {
            Button("Move topic to To Learn", role: .destructive) {
                Haptics.warning()
                Task { await model.markDidntLearn() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Suspends every card in this card's topic and moves them to the To Learn list.")
        }
    }

    // Always-available "Didn't Learn" action (both question and answer phases,
    // manual or voice modes). Mirrors the desktop reviewer's persistent button.
    @ViewBuilder
    private var didntLearnBar: some View {
        VStack(spacing: 4) {
            if let message = model.didntLearnMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            Button {
                confirmDidntLearn = true
            } label: {
                Label("Didn't Learn", systemImage: "questionmark.circle")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .background(
                Color.primary.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .disabled(model.currentCard == nil)
            .opacity(model.currentCard == nil ? 0.4 : 1)
            .accessibilityLabel("Didn't learn this topic")
            .accessibilityHint("Suspends every card in this topic and moves them to the To Learn list")
        }
    }

    // MARK: - Controls (automatic vs manual grading)

    @ViewBuilder
    private var controls: some View {
        if settings.autoGradeActive {
            autoGradeControls
        } else {
            manualControls
        }
    }

    @ViewBuilder
    private var manualControls: some View {
        if model.showingAnswer {
            gradingButtons
        } else {
            showAnswerButton
        }
    }

    private var showAnswerButton: some View {
        Button {
            Haptics.tap()
            model.revealAnswer()
        } label: {
            Label("Show Answer", systemImage: "eye")
        }
        .buttonStyle(MCATPrimaryButtonStyle())
        .accessibilityLabel("Show answer")
    }

    // Voice input on the question side; when the answer is shown we either wait
    // for the grade, or (on error/no speech) fall back to manual buttons.
    @ViewBuilder
    private var autoGradeControls: some View {
        if model.showingAnswer {
            if model.autoGrading {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Grading…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else {
                VStack(spacing: 8) {
                    if let message = model.autoGradeMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    gradingButtons
                }
            }
        } else {
            voiceInput
        }
    }

    private var voiceInput: some View {
        VStack(spacing: 12) {
            Text(model.voice.transcript.isEmpty
                ? "Tap Speak, say your answer, then Submit"
                : model.voice.transcript)
                .font(.body)
                .foregroundStyle(model.voice.transcript.isEmpty ? .secondary : .primary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 44)
                .padding(12)
                .background(
                    Color.primary.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )

            voiceStatus

            // Tooltip for the voice "didn't learn" command — spoken control that
            // moves the topic to To Learn instead of grading the answer.
            Text("Tip: say \u{201C}didn't learn\u{201D} to move this topic to To Learn")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            HStack(spacing: 12) {
                Button {
                    Haptics.tap()
                    Task {
                        if model.voice.isRecording {
                            _ = model.voice.stop()
                        } else {
                            await model.startVoiceInput()
                        }
                    }
                } label: {
                    Label(
                        model.voice.isRecording ? "Stop" : "Speak",
                        systemImage: model.voice.isRecording
                            ? "stop.circle.fill" : "mic.circle.fill"
                    )
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .foregroundStyle(model.voice.isRecording ? Color.red : MCATTheme.brand)
                    .background(
                        (model.voice.isRecording ? Color.red : MCATTheme.brand).opacity(0.14),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(
                                (model.voice.isRecording ? Color.red : MCATTheme.brand).opacity(0.35),
                                lineWidth: 1
                            )
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.voice.isRecording ? "Stop recording" : "Start recording")

                Button {
                    Task { await model.submitVoiceAnswer() }
                } label: {
                    Text("Submit")
                }
                .buttonStyle(MCATPrimaryButtonStyle())
                .disabled(
                    model.voice.transcript.trimmingCharacters(in: .whitespaces).isEmpty
                )
                .accessibilityLabel("Submit spoken answer")
            }
        }
    }

    @ViewBuilder
    private var voiceStatus: some View {
        switch model.voice.state {
        case let .denied(message), let .failed(message):
            Text(message)
                .font(.footnote)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        case .idle, .recording:
            EmptyView()
        }
    }

    private var finished: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(MCATTheme.correct.opacity(0.15))
                    .frame(width: 96, height: 96)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(MCATTheme.correct)
            }
            Text("All caught up")
                .font(.title2.bold())
            Text("Imported \(model.importedNotes) note(s).")
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .mcatCard()
        .padding(24)
        .accessibilityElement(children: .combine)
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("Something went wrong")
                .font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding(24)
        .mcatCard()
        .padding(24)
    }

    // MARK: - Pieces

    private var queueBar: some View {
        HStack(spacing: 10) {
            countPill(model.newCount, color: MCATTheme.amber, label: "New")
            countPill(model.learningCount, color: MCATTheme.amberBright, label: "Learning")
            countPill(model.reviewCount, color: MCATTheme.steel, label: "Review")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(model.newCount) new, \(model.learningCount) learning, \(model.reviewCount) review"
        )
    }

    private func countPill(_ value: UInt32, color: Color, label: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text("\(value)")
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(color)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(color.opacity(0.12), in: Capsule())
    }

    private var gradingButtons: some View {
        HStack(spacing: 8) {
            gradeButton("Again", .again, .red, "arrow.counterclockwise")
            gradeButton("Hard", .hard, .orange, "tortoise.fill")
            gradeButton("Good", .good, MCATTheme.correct, "checkmark")
            gradeButton("Easy", .easy, MCATTheme.brandBright, "hare.fill")
        }
    }

    private func gradeButton(
        _ title: String,
        _ rating: Anki_Scheduler_CardAnswer.Rating,
        _ color: Color,
        _ icon: String
    ) -> some View {
        Button {
            Haptics.tap()
            Task { await model.answer(rating) }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.title3)
                Text(title)
                    .font(.caption.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .foregroundStyle(color)
            .background(
                color.opacity(0.15),
                in: RoundedRectangle(cornerRadius: 13, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(color.opacity(0.4), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Grade \(title)")
    }
}
