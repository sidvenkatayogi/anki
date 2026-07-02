// Copyright: Ankitects Pty Ltd and contributors
// License: GNU AGPL, version 3 or later; http://www.gnu.org/licenses/agpl.html
//
// SyncView — the Account tab. Signed out shows a branded sign-in card; signed
// in shows a sync dashboard (status, media progress, Sync Now, Sign Out). The
// ambiguous full-sync case is resolved with a direction dialog.

import SwiftUI

struct SyncView: View {
    @Bindable var model: SyncModel

    // Login form state (server prefilled for local-dev; a physical device needs
    // the computer's LAN address instead of localhost).
    @State private var username = ""
    @State private var password = ""
    @State private var server = "http://localhost:8080/"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    header
                    if model.isLoggedIn {
                        dashboard
                    } else {
                        signInCard
                    }
                }
                .padding(20)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog(
                directionPrompt,
                isPresented: directionBinding,
                titleVisibility: .visible
            ) {
                Button("Download from server (replace this device)") {
                    Task { await model.resolveFullSync(upload: false) }
                }
                Button("Upload to server (replace server)") {
                    Task { await model.resolveFullSync(upload: true) }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(.white)
                .frame(width: 88, height: 88)
                .background(
                    LinearGradient(colors: [.indigo, .blue],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: .blue.opacity(0.3), radius: 10, y: 4)
            Text("MCAT Sync")
                .font(.title2.bold())
            Text("Keep your cards and FSRS progress in step across your computer and phone.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 8)
    }

    // MARK: - Signed out

    private var signInCard: some View {
        VStack(spacing: 16) {
            field(icon: "person.fill", title: "Username") {
                TextField("username", text: $username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            field(icon: "lock.fill", title: "Password") {
                SecureField("password", text: $password)
                    .textContentType(.password)
            }
            field(icon: "server.rack", title: "Sync server") {
                TextField("http://localhost:8080/", text: $server)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Button(action: { Task { await model.login(
                username: username, password: password, endpoint: server) } }) {
                HStack {
                    if model.isBusy { ProgressView().tint(.white) }
                    Text(model.isBusy ? "Signing in…" : "Sign In")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isBusy || username.isEmpty || password.isEmpty || server.isEmpty)

            statusLine

            Text("On a physical device, use your computer's address (e.g. http://192.168.1.20:8080/), not localhost.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .cardBackground()
    }

    // MARK: - Signed in

    private var dashboard: some View {
        VStack(spacing: 16) {
            // Account row
            HStack(spacing: 14) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.indigo)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.username.isEmpty ? "Signed in" : model.username)
                        .font(.headline)
                    Text(model.endpoint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }
            .padding(16)
            .cardBackground()

            // Status
            VStack(spacing: 12) {
                statusLine
                if let media = model.mediaProgress {
                    Label(media, systemImage: "photo.on.rectangle.angled")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button(action: { Task { await model.sync() } }) {
                    HStack {
                        if model.isBusy {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        Text(model.isBusy ? "Syncing…" : "Sync Now")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy)
            }
            .padding(20)
            .cardBackground()

            Button(role: .destructive, action: { model.logout() }) {
                Text("Sign Out")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.bordered)
            .disabled(model.isBusy)
        }
    }

    // MARK: - Shared bits

    @ViewBuilder
    private var statusLine: some View {
        switch model.phase {
        case .idle:
            EmptyView()
        case let .working(msg):
            Label(msg, systemImage: "arrow.triangle.2.circlepath")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case let .success(msg):
            Label(msg, systemImage: "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.green)
        case let .failure(msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.leading)
        case let .chooseDirection(msg):
            Label(msg, systemImage: "questionmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

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

    private var directionPrompt: String {
        if case let .chooseDirection(msg) = model.phase { return msg }
        return ""
    }

    private var directionBinding: Binding<Bool> {
        Binding(
            get: { if case .chooseDirection = model.phase { return true }; return false },
            set: { _ in }  // dismissal handled by the buttons
        )
    }
}

private extension View {
    func cardBackground() -> some View {
        background(Color(.secondarySystemGroupedBackground),
                   in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
