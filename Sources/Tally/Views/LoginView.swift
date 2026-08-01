import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var state: AppState
    @State private var token = ""
    @State private var isSigningIn = false
    @State private var errorMessage: String?
    @FocusState private var tokenFieldFocused: Bool

    private static let newTokenURL = URL(
        string: "https://github.com/settings/tokens/new?scopes=repo&description=Tally"
    )!

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 6) {
                AppIconTile(size: 56)
                Text("Tally")
                    .font(.title2.weight(.bold))
                Text("Sign in with GitHub to watch open pull requests from your menu bar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 20)

            GlassEffectContainer(spacing: 10) {
                VStack(spacing: 10) {
                    SecureField("Personal access token (ghp_… / github_pat_…)", text: $token)
                        .textFieldStyle(.plain)
                        .focused($tokenFieldFocused)
                        .padding(10)
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
                        .onSubmit(signIn)

                    Button(action: signIn) {
                        if isSigningIn {
                            ProgressView()
                                .controlSize(.small)
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Sign In")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSigningIn)
                }
            }
            .padding(.horizontal, 20)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }

            VStack(spacing: 4) {
                Link("Create a token on GitHub ↗", destination: Self.newTokenURL)
                    .font(.caption)
                Text("Needs the “repo” scope to read pull requests.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Divider()

            HStack {
                Spacer()
                Button("Quit Tally") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.bottom, 10)
        }
        .onAppear {
            // Give the panel a beat to become key before requesting focus.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                tokenFieldFocused = true
            }
        }
    }

    private func signIn() {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSigningIn else { return }
        isSigningIn = true
        errorMessage = nil
        Task {
            do {
                try await state.signIn(token: trimmed)
                token = ""
            } catch {
                errorMessage = error.localizedDescription
            }
            isSigningIn = false
        }
    }
}
