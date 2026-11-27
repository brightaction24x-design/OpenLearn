import SwiftUI
import Combine
import Network

@main
struct OpenLearnApp: App {
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false
    @State private var isLaunching = true

    var body: some Scene {
        WindowGroup {
            ZStack {
                OLTheme.background

                // Only one of these exists at a time. Nothing hidden underneath can
                // grab the keyboard and draw its focus ring across the welcome screen.
                if isLaunching {
                    LaunchView {
                        isLaunching = false
                    }
                    .transition(.opacity.combined(with: .scale(scale: 1.04)))
                    .zIndex(2)
                } else if hasSeenWelcome {
                    RootView()
                        .transition(.opacity.combined(with: .scale(scale: 1.03)))
                } else {
                    WelcomeView {
                        hasSeenWelcome = true
                    }
                    .transition(.opacity)
                    .zIndex(1)
                }

                // Sits above every screen and only shows when the connection is bad
                ConnectionBanner()
                    .zIndex(3)
            }
            .animation(.easeInOut(duration: 0.7), value: hasSeenWelcome)
            .animation(.easeInOut(duration: 0.6), value: isLaunching)
            .frame(minWidth: 900, minHeight: 620)
            .ignoresSafeArea()
            .background(OLWindowStyler())
            .tint(OLTheme.accent)
            .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
    }
}

// MARK: - Loading screen
/// Shown every time the app starts.
struct LaunchView: View {
    var onFinished: () -> Void

    @State private var progress: CGFloat = 0
    private let barWidth: CGFloat = 190

    var body: some View {
        ZStack {
            OLAmbientBackground()

            VStack(spacing: 22) {
                Image(systemName: "graduationcap.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(width: 84, height: 84)
                    .background(OLTheme.accentGradient, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .shadow(color: OLTheme.indigo.opacity(0.6), radius: 26, y: 10)
                    .olRiseIn()

                VStack(spacing: 8) {
                    Text("OpenLearn")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(OLTheme.textPrimary)
                    OLEyebrow("Loading your workspace", color: OLTheme.textMuted)
                }
                .olRiseIn(0.12)

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(OLTheme.border)
                    Capsule()
                        .fill(OLTheme.accentGradient)
                        .frame(width: barWidth * progress)
                }
                .frame(width: barWidth, height: 4)
                .olRiseIn(0.2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            withAnimation(.easeInOut(duration: 1.5).delay(0.25)) { progress = 1 }

            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            onFinished()
        }
    }
}

// MARK: - Connection status
enum ConnectionQuality {
    case online, slow, offline
}

/// Watches for a missing or very weak internet connection.
/// - Offline: no network at all, or the AI service can't be reached twice in a row.
/// - Slow: two checks in a row take over 3 seconds or time out.
@MainActor
final class ConnectionMonitor: ObservableObject {
    @Published private(set) var quality: ConnectionQuality = .online

    private var hasNetwork = true
    private var badChecks = 0

    /// Runs until the surrounding task is cancelled.
    func watch() async {
        let path = NWPathMonitor()
        path.pathUpdateHandler = { @Sendable [weak self] update in
            let connected = update.status == .satisfied
            Task { @MainActor [weak self] in
                self?.networkChanged(connected)
            }
        }
        path.start(queue: DispatchQueue(label: "OpenLearn.connection"))
        defer { path.cancel() }

        var ticks = 0
        while !Task.isCancelled {
            // Every 20 seconds while all is well, every 5 once something looks wrong
            let healthy = quality == .online && badChecks == 0
            if !healthy || ticks % 4 == 0 {
                await check()
            }
            ticks += 1
            try? await Task.sleep(for: .seconds(5))
        }
    }

    private func networkChanged(_ connected: Bool) {
        let wasConnected = hasNetwork
        hasNetwork = connected

        if !connected {
            quality = .offline
        } else if !wasConnected {
            Task { await check() }      // back on a network: confirm straight away
        }
    }

    /// A tiny request to Google's AI service. No API key or study data is sent.
    private func check() async {
        guard hasNetwork,
              let url = URL(string: "https://generativelanguage.googleapis.com/") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 8

        let started = Date()
        var problem: ConnectionQuality? = nil
        do {
            _ = try await URLSession.shared.data(for: request)
            if Date().timeIntervalSince(started) > 3 { problem = .slow }
        } catch {
            problem = (error as? URLError)?.code == .timedOut ? .slow : .offline
        }

        // The answer is stale if the app is closing or the network dropped meanwhile
        guard !Task.isCancelled, hasNetwork else { return }

        if let problem {
            badChecks += 1
            if badChecks >= 2 { quality = problem }
        } else {
            badChecks = 0
            quality = .online
        }
    }
}

/// The small notice at the top of the window.
struct ConnectionBanner: View {
    @StateObject private var monitor = ConnectionMonitor()
    @State private var showBackOnline = false

    var body: some View {
        VStack {
            if monitor.quality == .offline {
                pill("wifi.slash", "You're offline", "AI answers need internet", OLTheme.rose)
            } else if monitor.quality == .slow {
                pill("wifi.exclamationmark", "Weak connection", "Replies may be slow", OLTheme.amber)
            } else if showBackOnline {
                pill("wifi", "Back online", nil, OLTheme.green)
            }
            Spacer()
        }
        .padding(.top, 9)
        .frame(maxWidth: .infinity)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: monitor.quality)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: showBackOnline)
        .allowsHitTesting(false)        // clicks pass straight through
        .task { await monitor.watch() }
        .onChange(of: monitor.quality) { old, new in
            showBackOnline = old != .online && new == .online
        }
        .task(id: showBackOnline) {
            guard showBackOnline else { return }
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            showBackOnline = false
        }
    }

    private func pill(_ icon: String, _ title: String, _ detail: String?, _ color: Color) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(title)
                .fontWeight(.semibold)
                .foregroundStyle(OLTheme.textPrimary)
            if let detail {
                Text(detail)
                    .foregroundStyle(OLTheme.textSecondary)
            }
        }
        .font(.system(size: 12))
        .lineLimit(1)
        .padding(.horizontal, 18)
        .frame(minWidth: 300)
        .frame(height: 34)
        .olPanel(radius: 17, border: color.opacity(0.5))
        .shadow(color: Color.black.opacity(0.45), radius: 14, y: 6)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
