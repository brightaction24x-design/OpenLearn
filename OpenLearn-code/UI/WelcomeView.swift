//
//  WelcomeView.swift
//  OpenLearn
//
//  The opening screen: purple gradient, drifting bubbles and a Get Started button.
//

import SwiftUI

struct WelcomeView: View {
    var onGetStarted: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        ZStack {
            background

            VStack(spacing: 22) {
                Image(systemName: "graduationcap.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(Color.white)
                    .frame(width: 112, height: 112)
                    .background(Color.white.opacity(0.18), in: Circle())
                    .olRiseIn(0.1)

                Text("OpenLearn")
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.white)
                    .olRiseIn(0.25)

                Text("Study smarter with your own AI.")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .olRiseIn(0.4)

                startButton
                    .padding(.top, 8)
                    .olRiseIn(0.55)
            }
            .padding(32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }

    private var startButton: some View {
        Button(action: onGetStarted) {
            Text("Get Started")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(OLTheme.indigo)
                .padding(.horizontal, 38)
                .padding(.vertical, 13)
                .background(Color.white, in: Capsule())
                .shadow(color: Color.black.opacity(hovering ? 0.25 : 0.12), radius: hovering ? 16 : 8, y: 5)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
        .scaleEffect(hovering ? 1.04 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovering)
        .onHover { hovering = $0 }
    }

    private var background: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
            let time: Double = context.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                ZStack {
                    bubble(scale: 0.55, x: -0.16, y: -0.20, phase: time * 0.45, in: geo.size)
                    bubble(scale: 0.34, x: 0.10, y: -0.30, phase: time * 0.35 + 2, in: geo.size)
                    bubble(scale: 0.42, x: 0.22, y: 0.24, phase: time * 0.40 + 4, in: geo.size)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .background(
            LinearGradient(
                colors: [Color(olRGB: 0x7B7BFF), Color(olRGB: 0xD938F0), Color(olRGB: 0x1E90FF)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipped()
    }

    private func bubble(scale: CGFloat, x: CGFloat, y: CGFloat, phase: Double, in size: CGSize) -> some View {
        let diameter: CGFloat = size.width * scale
        let driftX: CGFloat = CGFloat(cos(phase)) * 30
        let driftY: CGFloat = CGFloat(sin(phase * 0.8)) * 36

        return Circle()
            .fill(Color.white.opacity(0.10))
            .frame(width: diameter, height: diameter)
            .offset(x: size.width * x + driftX, y: size.height * y + driftY)
    }
}
