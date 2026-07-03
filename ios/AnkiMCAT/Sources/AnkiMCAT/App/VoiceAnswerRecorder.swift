// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
// VoiceAnswerRecorder — records the mic and produces a live transcript with
// Apple's on-device speech recognition (SFSpeechRecognizer). Used by the review
// loop when automatic grading is on: the user speaks, we transcribe, and the
// transcript is sent to the LLM for grading. No audio leaves the device here.

import AVFoundation
import Foundation
import Speech

@MainActor
@Observable
final class VoiceAnswerRecorder {
    enum State: Equatable {
        case idle
        case recording
        case denied(String)
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var transcript: String = ""

    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

    var isRecording: Bool { state == .recording }

    /// Ask for speech + microphone permission. Returns true only if both are
    /// granted.
    func requestPermissions() async -> Bool {
        let speechAuthorized = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
        guard speechAuthorized else { return false }
        return await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }
    }

    /// Begin recording + live transcription. Safe to call repeatedly.
    func start() async {
        guard state != .recording else { return }
        transcript = ""

        guard await requestPermissions() else {
            state = .denied("Microphone or speech access is off. Enable it in the Settings app.")
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            state = .failed("Speech recognition isn't available right now.")
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition {
                request.requiresOnDeviceRecognition = true
            }
            self.request = request

            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            // Capture the request locally so the audio-thread tap doesn't touch
            // main-actor state; appending buffers off-thread is the intended use.
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }

            audioEngine.prepare()
            try audioEngine.start()
            state = .recording

            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                guard let self else { return }
                if let result {
                    Task { @MainActor in
                        self.transcript = result.bestTranscription.formattedString
                    }
                }
                if error != nil || (result?.isFinal ?? false) {
                    Task { @MainActor in self.teardown() }
                }
            }
        } catch {
            state = .failed(error.localizedDescription)
            teardown()
        }
    }

    /// Stop recording and return the transcript captured so far.
    @discardableResult
    func stop() -> String {
        teardown()
        return transcript
    }

    /// Fully reset for a fresh card.
    func reset() {
        teardown()
        transcript = ""
        state = .idle
    }

    private func teardown() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation
        )
        if state == .recording {
            state = .idle
        }
    }
}
