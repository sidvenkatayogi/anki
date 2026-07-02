// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
// PalaceStudyView — study a palace by location. Two modes (mixable):
//   • Recall ("what's here?"): a spot is highlighted; recall the card, reveal
//     it, and grade — the grade round-trips through the real FSRS scheduler.
//   • Locate ("where is it?"): the card is shown; tap the spot it lives in;
//     see if you were right, then grade.
// The spatial surface is the room photo/snapshot (works everywhere, including
// the Simulator) or live AR on a device with a saved world map.

import SwiftUI
import ARKit

/// Drives one study session over a palace's loci.
@MainActor
@Observable
final class PalaceStudySession {
    @ObservationIgnored let model: PalaceModel
    @ObservationIgnored let palaceID: UUID
    let steps: [StudyStep]

    private(set) var index = 0
    /// Recall: the card has been revealed (front shown).
    private(set) var revealed = false
    /// The card's answer (back) is shown.
    private(set) var showingAnswer = false
    private(set) var rendered: RenderedCard?
    /// Locate: the locus the user tapped, and whether it was correct.
    private(set) var locateSelection: UUID?
    private(set) var locateResult: Bool?
    private(set) var correctCount = 0
    private(set) var gradedCount = 0
    private(set) var finished = false
    /// The current card is being rendered (distinguishes "loading" from "gone").
    private(set) var loading = false
    /// A grade is in flight — guards against double-taps double-grading.
    private(set) var isGrading = false

    init(model: PalaceModel, palaceID: UUID, mode: StudyMode) {
        self.model = model
        self.palaceID = palaceID
        let loci = model.palace(palaceID)?.loci ?? []
        self.steps = PalaceLogic.buildSteps(order: loci.shuffled(), mode: mode)
    }

    var currentStep: StudyStep? { index < steps.count ? steps[index] : nil }

    var currentLocus: Locus? {
        guard let id = currentStep?.locusID else { return nil }
        return model.palace(palaceID)?.loci.first { $0.id == id }
    }

    /// During locate, only reveal the target highlight once answered.
    var highlightedLocusID: UUID? {
        guard let step = currentStep else { return nil }
        switch step.mode {
        case .recall: return step.locusID
        case .locate: return (locateResult != nil) ? step.locusID : nil
        case .mixed: return step.locusID
        }
    }

    func begin() async { await loadCurrent() }

    private func loadCurrent() async {
        rendered = nil
        guard let cid = currentLocus?.cardID else { return }
        loading = true
        rendered = await model.renderCard(cid)
        loading = false
    }

    // Recall
    func reveal() { revealed = true }
    func showAnswer() { showingAnswer = true }

    // Locate
    func selectLocate(_ locusID: UUID) {
        guard currentStep?.mode == .locate, locateResult == nil,
              let target = currentStep?.locusID else { return }
        locateSelection = locusID
        let correct = PalaceLogic.isLocateCorrect(selected: locusID, target: target)
        locateResult = correct
        if correct { correctCount += 1 }
        showingAnswer = true  // reveal the card so the user can grade
    }

    func grade(_ rating: Anki_Scheduler_CardAnswer.Rating) async {
        guard !isGrading, let locus = currentLocus else { return }
        isGrading = true
        let ok = await model.grade(cardID: locus.cardID, rating: rating)
        if ok {
            gradedCount += 1
            // Only ever mark as recalled — never un-mark a locus that was
            // previously recalled just because this pass was Again/Hard.
            if rating == .good || rating == .easy {
                model.markLearned(true, locusID: locus.id, palaceID: palaceID)
            }
        }
        // Advance regardless (a missing card shouldn't wedge the session), but
        // only successful grades count toward the tally.
        await advance()
        isGrading = false
    }

    private func advance() async {
        index += 1
        revealed = false
        showingAnswer = false
        locateSelection = nil
        locateResult = nil
        if index >= steps.count {
            finished = true
        } else {
            await loadCurrent()
        }
    }
}

struct PalaceStudyView: View {
    @Bindable var model: PalaceModel
    let palaceID: UUID

    @State private var mode: StudyMode = .mixed
    @State private var session: PalaceStudySession?
    // Loaded once from disk, not re-read on every body evaluation.
    @State private var studyImage: UIImage?
    @State private var worldMap: Data?

    private var palace: Palace? { model.palace(palaceID) }

    var body: some View {
        Group {
            if let session {
                if session.finished {
                    finishedView(session)
                } else {
                    stepView(session)
                }
            } else {
                setupView
            }
        }
        .navigationTitle("Study")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadAssets() }
    }

    /// Read the room photo + world map from disk once, off the body path.
    private func loadAssets() async {
        if studyImage == nil, let data = model.photoData(forPalace: palaceID) {
            studyImage = UIImage(data: data)
        }
        if worldMap == nil {
            worldMap = model.worldMapData(forPalace: palaceID)
        }
    }

    // MARK: - Setup

    private var setupView: some View {
        VStack(spacing: 20) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 48)).foregroundStyle(.tint)
            Text(palace?.name ?? "Palace").font(.title2.bold())
            Text("\(palace?.loci.count ?? 0) cards placed here")
                .foregroundStyle(.secondary)

            Picker("Mode", selection: $mode) {
                ForEach(StudyMode.allCases) { m in Text(m.title).tag(m) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            Text(modeExplanation)
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button {
                let s = PalaceStudySession(model: model, palaceID: palaceID, mode: mode)
                session = s
                Task { await s.begin() }
            } label: {
                Label("Start", systemImage: "play.fill").padding(.vertical, 6).padding(.horizontal, 16)
            }
            .buttonStyle(.borderedProminent)
            .disabled((palace?.loci.isEmpty ?? true))
        }
        .padding()
    }

    private var modeExplanation: String {
        switch mode {
        case .recall: return "A spot lights up — recall which card lives there, then grade yourself."
        case .locate: return "A card is shown — tap the spot where it lives, then grade yourself."
        case .mixed: return "Alternate between recalling the card at a spot and finding where a card lives."
        }
    }

    // MARK: - Step

    @ViewBuilder
    private func stepView(_ session: PalaceStudySession) -> some View {
        VStack(spacing: 0) {
            progressBar(session)
            Divider()
            if let step = session.currentStep {
                switch step.mode {
                case .locate: locateStep(session)
                default: recallStep(session)
                }
            }
        }
    }

    private func progressBar(_ session: PalaceStudySession) -> some View {
        HStack {
            Text("\(min(session.index + 1, session.steps.count)) / \(session.steps.count)")
                .font(.subheadline.monospacedDigit())
            Spacer()
            if let step = session.currentStep {
                Label(step.mode == .locate ? "Where is it?" : "What's here?",
                      systemImage: step.mode == .locate ? "mappin.and.ellipse" : "questionmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            // "correct" is only meaningful for locate steps; recall is self-graded.
            if session.steps.contains(where: { $0.mode == .locate }) {
                Text("✓ \(session.correctCount)")
                    .font(.subheadline).foregroundStyle(.green)
                    .accessibilityLabel("\(session.correctCount) located correctly")
            }
        }
        .padding(10)
    }

    // Recall: highlight the spot, recall the card, reveal, grade.
    @ViewBuilder
    private func recallStep(_ session: PalaceStudySession) -> some View {
        spatialSurface(session, allowTap: false)
            .frame(maxHeight: .infinity)

        Divider()

        if !session.revealed {
            VStack(spacing: 12) {
                Text("What card is at the highlighted spot?")
                    .font(.headline).multilineTextAlignment(.center)
                Button("Reveal card") { session.reveal() }
                    .buttonStyle(.borderedProminent)
            }
            .padding()
        } else {
            cardAndGrading(session)
        }
    }

    // Locate: show the card, tap the spot, feedback, grade.
    @ViewBuilder
    private func locateStep(_ session: PalaceStudySession) -> some View {
        cardFront(session)
            .frame(maxHeight: 220)

        Divider()

        if session.locateResult == nil {
            Text("Tap the spot where this card lives")
                .font(.headline).padding(.top, 6)
        } else {
            Label(session.locateResult == true ? "Correct!" : "Not quite — here it is",
                  systemImage: session.locateResult == true ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(session.locateResult == true ? .green : .red)
                .font(.headline).padding(.top, 6)
        }

        spatialSurface(session, allowTap: session.locateResult == nil)
            .frame(maxHeight: .infinity)

        if session.locateResult != nil {
            Divider()
            gradingButtons(session)
        }
    }

    // MARK: - Card + grading

    @ViewBuilder
    private func cardAndGrading(_ session: PalaceStudySession) -> some View {
        VStack(spacing: 0) {
            if let rendered = session.rendered {
                CardWebView(
                    html: session.showingAnswer ? rendered.answer : rendered.question,
                    css: rendered.css)
                    .frame(maxHeight: 220)
            } else if session.loading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            } else {
                unavailableCard
            }
            Divider()
            if session.showingAnswer {
                gradingButtons(session)
            } else {
                Button("Show answer") { session.showAnswer() }
                    .buttonStyle(.borderedProminent)
                    .padding()
            }
        }
    }

    @ViewBuilder
    private func cardFront(_ session: PalaceStudySession) -> some View {
        if let rendered = session.rendered {
            CardWebView(html: session.showingAnswer ? rendered.answer : rendered.question,
                        css: rendered.css)
        } else if session.loading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            unavailableCard
        }
    }

    private var unavailableCard: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            Text("This card is no longer available.").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func gradingButtons(_ session: PalaceStudySession) -> some View {
        HStack(spacing: 8) {
            gradeButton("Again", .again, .red, session)
            gradeButton("Hard", .hard, .orange, session)
            gradeButton("Good", .good, .green, session)
            gradeButton("Easy", .easy, .blue, session)
        }
        .padding()
    }

    private func gradeButton(_ title: String, _ rating: Anki_Scheduler_CardAnswer.Rating,
                             _ color: Color, _ session: PalaceStudySession) -> some View {
        Button {
            Task { await session.grade(rating) }
        } label: {
            Text(title).frame(maxWidth: .infinity).padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
        .tint(color)
        .disabled(session.isGrading)
    }

    // MARK: - Spatial surface

    @ViewBuilder
    private func spatialSurface(_ session: PalaceStudySession, allowTap: Bool) -> some View {
        if useARForStudy, let palace {
            ARPalaceView(
                mode: .study,
                loci: palace.loci,
                highlightedLocusID: session.highlightedLocusID,
                initialWorldMapData: worldMap,
                onSelected: { if allowTap { session.selectLocate($0) } })
                .ignoresSafeArea(edges: .bottom)
        } else if let image = studyImage, let palace {
            PhotoPalaceView(
                image: image,
                loci: palace.loci,
                highlightedLocusID: session.highlightedLocusID,
                showLabels: false,
                onSelectLocus: { if allowTap { session.selectLocate($0) } })
        } else {
            noSurface
        }
    }

    private var useARForStudy: Bool {
        ARWorldTrackingConfiguration.isSupported
            && (palace?.hasWorldMap ?? false)
            && worldMap != nil
    }

    private var noSurface: some View {
        ContentUnavailableView(
            "No room view", systemImage: "photo",
            description: Text("This palace has no photo or spatial map to study against."))
    }

    // MARK: - Finished

    private func finishedView(_ session: PalaceStudySession) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56)).foregroundStyle(.green)
            Text("Session complete").font(.title2.bold())
            Text("Graded \(session.gradedCount) card\(session.gradedCount == 1 ? "" : "s") through your scheduler.")
                .foregroundStyle(.secondary)
            if session.steps.contains(where: { $0.mode == .locate }) {
                Text("Located \(session.correctCount) correctly.")
                    .foregroundStyle(.secondary)
            }
            Button("Done") { self.session = nil }
                .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}
