import SwiftUI

struct OnboardingContainerView: View {
    @Binding var userName: String
    @Binding var apiKey: String
    @Binding var hasCompletedOnboarding: Bool
    var onReady: () -> Void

    @State private var step: Int = 1
    @State private var tempName: String = ""
    @State private var tempKey: String = ""
    @State private var showError: Bool = false
    @State private var errorMessage: String = ""
    @State private var showTermsSheet: Bool = false
    @State private var isVerifying: Bool = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(nsColor: .windowBackgroundColor), Color.indigo.opacity(0.15)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 24) {
                // Header Branding
                VStack(spacing: 8) {
                    Image(systemName: "book.closed.fill")
                        .font(.system(size: 50))
                        .foregroundStyle(.indigo)
                        .padding()
                        .background(.ultraThinMaterial, in: Circle())

                    Text("OpenLearn")
                        .font(.system(.largeTitle, design: .rounded))
                        .fontWeight(.bold)

                    Text("Your zero-paywall, AI-powered study companion.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 40)

                // Card Content
                VStack(spacing: 20) {
                    if step == 1 {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Welcome! Let's get to know you.")
                                .font(.headline)

                            Text("Your name keeps your study sets organized on your Mac.")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            TextField("Full Name (e.g., Abdullah)", text: $tempName)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { handleNextButton() }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Connect your AI API Key")
                                .font(.headline)

                            Text("OpenLearn checks your key with Google before continuing.")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            SecureField("Paste API Key (AQ... or AIza...)", text: $tempKey)
                                .textFieldStyle(.roundedBorder)
                                .disabled(isVerifying)
                                .onSubmit { handleNextButton() }

                            HStack {
                                Button {
                                    showTermsSheet = true
                                } label: {
                                    Label("Learn more about keys & privacy", systemImage: "info.circle.fill")
                                        .font(.footnote)
                                        .foregroundColor(.indigo)
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
                                        .foregroundColor(.indigo)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    if isVerifying {
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.6)
                            Text("Verifying your key with Google...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if showError {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(24)
                .background(.ultraThinMaterial)
                .cornerRadius(20)
                .padding(.horizontal, 40)

                Spacer()

                // Footer Navigation Buttons
                HStack(spacing: 16) {
                    if step == 2 {
                        Button("Back") {
                            showError = false
                            withAnimation { step = 1 }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isVerifying)
                    }

                    Button(step == 1 ? "Continue" : (isVerifying ? "Verifying..." : "Launch OpenLearn")) {
                        handleNextButton()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.indigo)
                    .disabled(isVerifying)
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 30)
            }
        }
        .sheet(isPresented: $showTermsSheet) {
            VStack(spacing: 16) {
                Text("OpenLearn Privacy & API Keys")
                    .font(.headline)
                Text("OpenLearn uses a BYOK (Bring Your Own Key) model. Your API key is stored in your Mac's Keychain and is sent only to Google's Gemini API to verify it and when you send a message. It is never sent to OpenLearn or any other server.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
                Button("Close") {
                    showTermsSheet = false
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(24)
            .frame(width: 420, height: 300)
        }
    }

    private func handleNextButton() {
        guard !isVerifying else { return }
        showError = false

        if step == 1 {
            let trimmedName = tempName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else {
                errorMessage = "Please enter your name."
                showError = true
                return
            }
            userName = trimmedName
            withAnimation { step = 2 }
            return
        }

        // Step 2: verify the key with Google before letting the user in
        let trimmedKey = tempKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedKey.isEmpty else {
            errorMessage = "Please paste your AI API key."
            showError = true
            return
        }
        guard !trimmedKey.contains(" "), trimmedKey.count >= 20 else {
            errorMessage = "That doesn't look like a full API key. Copy the whole key with no spaces."
            showError = true
            return
        }

        isVerifying = true

        Task { @MainActor in
            do {
                try await GeminiService.verifyKey(trimmedKey)
                // Google accepted the key
                apiKey = trimmedKey
                hasCompletedOnboarding = true
                isVerifying = false
                onReady()
            } catch let error as GeminiError {
                errorMessage = error.localizedDescription
                showError = true
                isVerifying = false
            } catch {
                let nsError = error as NSError
                errorMessage = "Network error \(nsError.code): \(nsError.localizedDescription)"
                showError = true
                isVerifying = false
            }            }
        }
    }

