import SwiftUI
import AppKit

struct OnboardingContainerView: View {
    @Binding var userName: String
    @Binding var apiKey: String
    @Binding var hasCompletedOnboarding: Bool
    let startAtKeyStep: Bool
    let keychainNotice: String?
    let onRetryKeychain: () -> Void
    let onReady: () -> Void

    private enum Field {
        case name
        case key
    }

    @State private var step: Int = 1
    @State private var tempName: String = ""
    @State private var tempKey: String = ""
    @State private var showError: Bool = false
    @State private var errorMessage: String = ""
    @State private var showTermsSheet: Bool = false
    @State private var isVerifying: Bool = false
    @FocusState private var focus: Field?

    private let stepAnimation = Animation.spring(response: 0.45, dampingFraction: 0.86)

    init(
        userName: Binding<String>,
        apiKey: Binding<String>,
        hasCompletedOnboarding: Binding<Bool>,
        startAtKeyStep: Bool = false,
        keychainNotice: String? = nil,
        onRetryKeychain: @escaping () -> Void = {},
        onReady: @escaping () -> Void
    ) {
        _userName = userName
        _apiKey = apiKey
        _hasCompletedOnboarding = hasCompletedOnboarding
        self.startAtKeyStep = startAtKeyStep
        self.keychainNotice = keychainNotice
        self.onRetryKeychain = onRetryKeychain
        self.onReady = onReady
    }

    var body: some View {
        VStack(spacing: 24) {
            header
                .olRiseIn(0.05)
            card
                .olRiseIn(0.15)
            buttons
                .olRiseIn(0.25)
        }
        .frame(maxWidth: 460)
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            tempName = userName
            if startAtKeyStep { step = 2 }
            focusCurrentField()
        }
        .sheet(isPresented: $showTermsSheet) {
            privacySheet
        }
    }

    // MARK: Header branding
    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "graduationcap.fill")
                .font(.system(size: 34))
                .foregroundStyle(.white)
                .frame(width: 84, height: 84)
                .background(OLTheme.accentGradient, in: Circle())
                .shadow(color: OLTheme.indigo.opacity(0.55), radius: 26, y: 8)

            Text("OpenLearn")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(OLTheme.textPrimary)

            Text("Your zero-paywall, AI-powered study companion.")
                .font(.system(size: 13))
                .foregroundStyle(OLTheme.textSecondary)
        }
    }

    // MARK: Card content
    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            if step == 1 {
                nameStep
                    .transition(.move(edge: .leading).combined(with: .opacity))
            } else {
                keyStep
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            if isVerifying {
                HStack(spacing: 10) {
                    OLTypingDots()
                    Text("Verifying your key with Google...")
                        .font(.caption)
                        .foregroundStyle(OLTheme.textSecondary)
                }
                .transition(.opacity)
            }

            if showError {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(OLTheme.rose)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .olPanel(radius: 20, fill: OLTheme.surface.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var nameStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            OLEyebrow("Step 1 of 2 · About you", color: OLTheme.textMuted)

            Text("Welcome! Let's get to know you.")
                .font(.headline)
                .foregroundStyle(OLTheme.textPrimary)

            Text("Your name keeps your study sets organized on your Mac.")
                .font(.caption)
                .foregroundStyle(OLTheme.textSecondary)

            TextField("", text: $tempName, prompt: Text("Full Name (e.g., Abdullah)").foregroundColor(OLTheme.textMuted))
                .textFieldStyle(.plain)
                .focused($focus, equals: .name)
                .onSubmit { handleNextButton() }
                .olField(focused: focus == .name)
        }
    }

    private var keyStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            OLEyebrow("Step 2 of 2 · Connect Gemini", color: OLTheme.textMuted)

            Text("Connect your AI API Key")
                .font(.headline)
                .foregroundStyle(OLTheme.textPrimary)

            Text("OpenLearn checks your key with Google before continuing.")
                .font(.caption)
                .foregroundStyle(OLTheme.textSecondary)

            if let keychainNotice {
                VStack(alignment: .leading, spacing: 8) {
                    Text(keychainNotice)
                        .font(.caption)
                        .foregroundStyle(OLTheme.amber)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Try the Keychain again", action: onRetryKeychain)
                        .buttonStyle(.olGhost)
                }
            }

            SecureField("", text: $tempKey, prompt: Text("Paste API Key (AQ... or AIza...)").foregroundColor(OLTheme.textMuted))
                .textFieldStyle(.plain)
                .focused($focus, equals: .key)
                .disabled(isVerifying)
                .onSubmit { handleNextButton() }
                .olField(focused: focus == .key)

            HStack {
                Button {
                    showTermsSheet = true
                } label: {
                    Label("Learn more about keys & privacy", systemImage: "info.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(OLTheme.accentSoft)
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    if let url = URL(string: "https://aistudio.google.com/app/apikey") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Text("Get Gemini Key")
                        .font(.footnote)
                        .foregroundStyle(OLTheme.accentSoft)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Footer navigation buttons
    private var buttons: some View {
        HStack(spacing: 14) {
            if step == 2 {
                Button("Back") {
                    showError = false
                    withAnimation(stepAnimation) { step = 1 }
                    focusCurrentField()
                }
                .buttonStyle(.olGhost)
                .disabled(isVerifying)
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }

            Button(step == 1 ? "Continue" : (isVerifying ? "Verifying..." : "Launch OpenLearn")) {
                handleNextButton()
            }
            .buttonStyle(.olAccent)
            .disabled(isVerifying)
        }
    }

    private var privacySheet: some View {
        VStack(spacing: 16) {
            Text("OpenLearn Privacy & API Keys")
                .font(.headline)
            Text("OpenLearn uses a BYOK (Bring Your Own Key) model. Your API key is stored in your Mac's Keychain and sent only to Google's Gemini API. When you use the AI features, your messages and the files you add are sent to Google too, under Google's terms. OpenLearn has no server of its own.")
                .font(.body)
                .foregroundStyle(OLTheme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Close") {
                showTermsSheet = false
            }
            .buttonStyle(.olAccent)
        }
        .padding(28)
        .frame(width: 440)
        .background(OLTheme.surface)
    }

    // MARK: Actions
    private func focusCurrentField() {
        Task { @MainActor in
            // Wait for the field to slide into place first
            try? await Task.sleep(for: .milliseconds(350))
            let next: Field = step == 1 ? .name : .key
            focus = next
        }
    }

    private func fail(_ message: String) {
        withAnimation(.easeOut(duration: 0.2)) {
            errorMessage = message
            showError = true
        }
    }

    private func handleNextButton() {
        guard !isVerifying else { return }
        showError = false

        if step == 1 {
            let trimmedName = tempName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else {
                fail("Please enter your name.")
                return
            }
            userName = trimmedName
            withAnimation(stepAnimation) { step = 2 }
            focusCurrentField()
            return
        }

        // Step 2: verify the key with Google before letting the user in
        let trimmedKey = tempKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedKey.isEmpty else {
            fail("Please paste your AI API key.")
            return
        }
        guard !trimmedKey.contains(" "), trimmedKey.count >= 20 else {
            fail("That doesn't look like a full API key. Copy the whole key with no spaces.")
            return
        }

        withAnimation { isVerifying = true }

        Task { @MainActor in
            do {
                try await GeminiService.verifyKey(trimmedKey)
                // Google accepted the key
                apiKey = trimmedKey
                hasCompletedOnboarding = true
                isVerifying = false
                onReady()
            } catch let error as GeminiError {
                isVerifying = false
                fail(error.localizedDescription)
            } catch {
                let nsError = error as NSError
                isVerifying = false
                fail("Network error \(nsError.code): \(nsError.localizedDescription)")
            }
        }
    }
}
