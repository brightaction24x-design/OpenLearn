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
    @State private var keychainNotice: String?
    @State private var showSaveFailed = false

    init() {
        var key = ""
        var notice: String?

        switch KeychainStore.read("apiKey") {
        case .found(let saved):
            key = saved
        case .missing:
            break
        case .failed(let status):
            notice = "OpenLearn couldn't read your saved key from the Keychain (error \(status)). Try again, and choose Always Allow if macOS asks."
        }

        // If an old plaintext key exists in UserDefaults, move it to the Keychain.
        // The plaintext copy is deleted only once the Keychain really has it.
        if let legacy = UserDefaults.standard.string(forKey: "apiKey"), !legacy.isEmpty {
            if key.isEmpty { key = legacy }
            if KeychainStore.set(key, for: "apiKey") {
                UserDefaults.standard.removeObject(forKey: "apiKey")
            }
        }

        let done = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        _apiKey = State(initialValue: key)
        // Never open the dashboard without a key
        _phase = State(initialValue: (done && !key.isEmpty) ? .dashboard : .onboarding)
        _keychainNotice = State(initialValue: (done && key.isEmpty) ? notice : nil)
    }

    var body: some View {
        ZStack {
            // One background shared by onboarding and the ready screen, so it never jumps
            if phase != .dashboard {
                OLAmbientBackground()
                    .transition(.opacity)
            }

            switch phase {
            case .onboarding:
                OnboardingContainerView(
                    userName: $userName,
                    apiKey: $apiKey,
                    hasCompletedOnboarding: $hasCompletedOnboarding,
                    startAtKeyStep: hasCompletedOnboarding && !userName.isEmpty,
                    keychainNotice: keychainNotice,
                    onRetryKeychain: retryKeychain,
                    onReady: {
                        showSaveFailed = !KeychainStore.set(apiKey, for: "apiKey")
                        keychainNotice = nil
                        phase = .transition
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.97)))

            case .transition:
                WorkspaceReadyTransitionView(userName: userName) {
                    phase = .dashboard
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96)))

            case .dashboard:
                ContentView(apiKey: apiKey, onReset: resetApp)
                    .transition(.opacity.combined(with: .scale(scale: 1.02)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.5), value: phase)
        .onChange(of: apiKey) { _, newValue in
            KeychainStore.set(newValue, for: "apiKey")
        }
        .alert("Your key couldn't be saved", isPresented: $showSaveFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("macOS refused to write to the Keychain, so OpenLearn will ask for the key again next launch. In Xcode, choose a Team under Signing & Capabilities, then run again.")
        }
    }

    private func retryKeychain() {
        switch KeychainStore.read("apiKey") {
        case .found(let saved):
            keychainNotice = nil
            apiKey = saved
            phase = .dashboard
        case .missing:
            keychainNotice = "There's no saved key in the Keychain. Paste it below."
        case .failed(let status):
            keychainNotice = "Still blocked (error \(status)). Paste your key below to save it again."
        }
    }

    private func resetApp() {
        apiKey = ""
        KeychainStore.set("", for: "apiKey")
        keychainNotice = nil
        hasCompletedOnboarding = false
        phase = .onboarding
    }
}
