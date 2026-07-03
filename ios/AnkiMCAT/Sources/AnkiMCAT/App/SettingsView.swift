// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
// SettingsView — the Settings tab. Lets the user turn automatic (voice + AI)
// grading on/off and paste their OpenAI API key. Both are stored per-device by
// SettingsModel/SettingsStore.

import SwiftUI

struct SettingsView: View {
    @Bindable var model: SettingsModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Automatic grading", isOn: $model.autoGradeEnabled)
                } header: {
                    Text("Grading")
                } footer: {
                    Text(
                        "When on, speak your answer and tap Submit — AI checks it and picks the rating automatically based on how fast you answered. When off, you reveal the answer and grade yourself."
                    )
                }

                Section {
                    SecureField("sk-...", text: $model.openAIKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.password)
                } header: {
                    Text("OpenAI API key")
                } footer: {
                    Text(
                        "Required for automatic grading (uses \(LLMGrader.model)). Stored only on this device, in the Keychain."
                    )
                }

                if model.autoGradeEnabled && !model.autoGradeActive {
                    Section {
                        Label(
                            "Add an API key to start grading automatically.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}
