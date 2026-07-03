// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
// ReviewView — the single review screen. Renders the current card, a
// Show Answer button, then Again/Hard/Good/Easy grading buttons that round-trip
// through the shared Rust scheduler (C4). Kept intentionally plain — this is a
// functional review loop, not a designed UI.

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
            .navigationTitle("Anki MCAT")
        }
    }

    // MARK: - Phases

    private var launching: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(model.statusLine)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var reviewing: some View {
        VStack(spacing: 0) {
            queueBar

            CardWebView(
                html: model.showingAnswer ? model.answerHTML : model.questionHTML,
                css: model.cardCSS
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            controls

            didntLearnBar
        }
        .confirmationDialog(
            "Mark this topic as not yet learned?",
            isPresented: $confirmDidntLearn,
            titleVisibility: .visible
        ) {
            Button("Move topic to To Learn", role: .destructive) {
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
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.bordered)
            .tint(.secondary)
            .disabled(model.currentCard == nil)
            .help("Mark this topic as not yet learned — suspends its cards and moves them to To Learn")
            .accessibilityLabel("Didn't learn this topic")
            .accessibilityHint("Suspends every card in this topic and moves them to the To Learn list")
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
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
            model.revealAnswer()
        } label: {
            Text("Show Answer")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .padding()
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
                .padding()
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
                .padding(.bottom, 4)
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
                .padding(.horizontal)

            voiceStatus

            // Tooltip for the voice "didn't learn" command — spoken control that
            // moves the topic to To Learn instead of grading the answer.
            Text("Tip: say \u{201C}didn't learn\u{201D} to move this topic to To Learn")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
                .help("Speak \u{201C}didn't learn\u{201D} to mark this topic as not yet learned")

            HStack(spacing: 12) {
                Button {
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
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .tint(model.voice.isRecording ? .red : .blue)
                .accessibilityLabel(model.voice.isRecording ? "Stop recording" : "Start recording")

                Button {
                    Task { await model.submitVoiceAnswer() }
                } label: {
                    Text("Submit")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    model.voice.transcript.trimmingCharacters(in: .whitespaces).isEmpty
                )
                .accessibilityLabel("Submit spoken answer")
            }
        }
        .padding()
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
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text("All caught up")
                .font(.title2)
            Text("Imported \(model.importedNotes) note(s).")
                .foregroundStyle(.secondary)
        }
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
    }

    // MARK: - Pieces

    private var queueBar: some View {
        HStack(spacing: 20) {
            countPill(model.newCount, color: .blue, label: "new")
            countPill(model.learningCount, color: .red, label: "learning")
            countPill(model.reviewCount, color: .green, label: "review")
        }
        .font(.subheadline.monospacedDigit())
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(model.newCount) new, \(model.learningCount) learning, \(model.reviewCount) review"
        )
    }

    private func countPill(_ value: UInt32, color: Color, label: String) -> some View {
        Text("\(value)")
            .foregroundStyle(color)
            .accessibilityLabel("\(value) \(label)")
    }

    private var gradingButtons: some View {
        HStack(spacing: 8) {
            gradeButton("Again", .again, .red)
            gradeButton("Hard", .hard, .orange)
            gradeButton("Good", .good, .green)
            gradeButton("Easy", .easy, .blue)
        }
        .padding()
    }

    private func gradeButton(
        _ title: String,
        _ rating: Anki_Scheduler_CardAnswer.Rating,
        _ color: Color
    ) -> some View {
        Button {
            Task { await model.answer(rating) }
        } label: {
            Text(title)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
        .tint(color)
        .accessibilityLabel("Grade \(title)")
    }
}
