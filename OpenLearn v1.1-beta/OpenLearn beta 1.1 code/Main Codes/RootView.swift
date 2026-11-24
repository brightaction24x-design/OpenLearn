import SwiftUI

enum AppPhase {
    case onboarding
    case transition
    case dashboard
}

struct RootView: View {
    @AppStorage("userName") private var userName: String = ""
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding: Bool = false

    @State private var apiKey: String
    @State private var phase: AppPhase

    init() {
        // Read the key from the Keychain. If an old plaintext key exists in
        // UserDefaults, move it to the Keychain and delete the plaintext copy.
        var key = KeychainStore.get("apiKey")
        if key.isEmpty,
           let legacy = UserDefaults.standard.string(forKey: "apiKey"),
           !legacy.isEmpty {
            KeychainStore.set(legacy, for: "apiKey")
            key = legacy
        }
        UserDefaults.standard.removeObject(forKey: "apiKey")

        let done = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        _apiKey = State(initialValue: key)
        // Never open the dashboard without a key
        _phase = State(initialValue: (done && !key.isEmpty) ? .dashboard : .onboarding)
    }

    var body: some View {
        Group {
            switch phase {
            case .onboarding:
                OnboardingContainerView(
                    userName: $userName,
                    apiKey: $apiKey,
                    hasCompletedOnboarding: $hasCompletedOnboarding,
                    onReady: {
                        KeychainStore.set(apiKey, for: "apiKey")
                        phase = .transition
                    }
                )
                .transition(.opacity)

            case .transition:
                WorkspaceReadyTransitionView(userName: userName) {
                    phase = .dashboard
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96)))

            case .dashboard:
                ContentView(apiKey: apiKey, onReset: resetApp)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: phase)
        .onChange(of: apiKey) { _, newValue in
            KeychainStore.set(newValue, for: "apiKey")
        }
        .overlay(alignment: .bottomTrailing) {
            #if DEBUG
            // Testing button: only exists in Debug builds, never in a release
            Button("Reset onboarding", action: resetApp)
                .controlSize(.small)
                .padding(12)
            #endif
        }
    }

    private func resetApp() {
        apiKey = ""
        KeychainStore.set("", for: "apiKey")
        hasCompletedOnboarding = false
        phase = .onboarding
    }
}
