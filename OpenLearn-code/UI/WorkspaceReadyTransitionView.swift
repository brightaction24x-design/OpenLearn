import SwiftUI

struct WorkspaceReadyTransitionView: View {
    let userName: String
    var onFinished: () -> Void

    @State private var showRing = false
    @State private var showCheck = false
    @State private var progress: CGFloat = 0

    private let barWidth: CGFloat = 180

    var body: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(OLTheme.indigo.opacity(0.18))
                    .frame(width: 132, height: 132)
                    .scaleEffect(showRing ? 1 : 0.6)
                    .opacity(showRing ? 1 : 0)

                Circle()
                    .trim(from: 0, to: showRing ? 1 : 0)
                    .stroke(OLTheme.accentGradient, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 106, height: 106)
                    .rotationEffect(.degrees(-90))

                Circle()
                    .fill(OLTheme.accentGradient)
                    .frame(width: 80, height: 80)
                    .scaleEffect(showCheck ? 1 : 0.01)
                    .shadow(color: OLTheme.indigo.opacity(0.6), radius: 24, y: 8)

                Image(systemName: "checkmark")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(.white)
                    .scaleEffect(showCheck ? 1 : 0.3)
                    .opacity(showCheck ? 1 : 0)
            }

            VStack(spacing: 8) {
                Text(userName.isEmpty ? "You're all set!" : "You're all set, \(userName)!")
                    .font(.system(.largeTitle, design: .rounded))
                    .fontWeight(.bold)
                    .foregroundStyle(OLTheme.textPrimary)
                    .olRiseIn(0.35)

                Text("Your OpenLearn workspace is ready.")
                    .font(.title3)
                    .foregroundStyle(OLTheme.textSecondary)
                    .olRiseIn(0.45)
            }

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(OLTheme.border)
                Capsule()
                    .fill(OLTheme.accentGradient)
                    .frame(width: barWidth * progress)
            }
            .frame(width: barWidth, height: 4)
            .olRiseIn(0.5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            withAnimation(.easeOut(duration: 0.7)) { showRing = true }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.62).delay(0.3)) { showCheck = true }
            withAnimation(.easeInOut(duration: 1.8).delay(0.5)) { progress = 1 }

            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            onFinished()
        }
    }
}
