import SwiftUI

struct WorkspaceReadyTransitionView: View {
    let userName: String
    var onFinished: () -> Void

    @State private var animateIcon = false
    @State private var animateText = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(nsColor: .windowBackgroundColor), Color.indigo.opacity(0.18)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .fill(Color.indigo.opacity(0.15))
                        .frame(width: 110, height: 110)
                        .scaleEffect(animateIcon ? 1.15 : 0.7)
                        .opacity(animateIcon ? 1 : 0)

                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.indigo)
                        .scaleEffect(animateIcon ? 1.0 : 0.4)
                        .rotationEffect(.degrees(animateIcon ? 0 : -30))
                }

                VStack(spacing: 8) {
                    Text("You're all set, \(userName)!")
                        .font(.system(.largeTitle, design: .rounded))
                        .fontWeight(.bold)

                    Text("Your OpenLearn workspace is ready.")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
                .opacity(animateText ? 1 : 0)
                .offset(y: animateText ? 0 : 15)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.65)) {
                animateIcon = true
            }
            withAnimation(.easeOut(duration: 0.5).delay(0.2)) {
                animateText = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                onFinished()
            }
        }
    }
}
