import Foundation
import SwiftUI

struct LoaderView: View {
    @State private var progress: Double = 0
    @State private var started = false
    @State private var timer: Timer?

    private let telegramURL = URL(string: "https://t.me/ascentios")!

    private let stages: [(limit: Double, label: String)] = [
        (30,  "initializing"),
        (65,  "connecting"),
        (90,  "checking files"),
        (100, "ready")
    ]

    private var statusLabel: String {
        if started { return "launching" }
        for stage in stages where progress <= stage.limit {
            return stage.label
        }
        return "ready"
    }

    private var isReady: Bool { progress >= 100 }

    var body: some View {
        ZStack {
            background.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                logoMark

                Text("ascent")
                    .font(.system(size: 46, weight: .heavy, design: .rounded))
                    .foregroundColor(Theme.text)
                    .padding(.top, 26)

                Text("LOADER")
                    .font(.system(size: 10, weight: .semibold))
                    .kerning(4)
                    .foregroundColor(Theme.muted)
                    .padding(.top, 10)

                progressCard
                    .padding(.top, 44)

                startButton
                    .padding(.top, 22)

                Spacer(minLength: 0)

                telegramLink
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
        }
        .onAppear(perform: beginLoading)
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }

    // MARK: - Части экрана

    private var background: some View {
        ZStack {
            Theme.bg
            RadialGradient(
                colors: [Theme.green.opacity(0.16), Color.clear],
                center: UnitPoint(x: 0.5, y: 0.10),
                startRadius: 0,
                endRadius: 430
            )
        }
    }

    private var logoMark: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(colors: [Theme.green.opacity(0.14), Color.white.opacity(0.02)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 72, height: 72)
                .shadow(color: Theme.green.opacity(0.35), radius: 22, x: 0, y: 14)

            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Theme.line, lineWidth: 1)
                .frame(width: 72, height: 72)

            Image(systemName: "arrow.up")
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(Theme.green)
                .shadow(color: Theme.green.opacity(0.6), radius: 8)
        }
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(statusLabel.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .kerning(2)
                    .foregroundColor(Theme.muted)
                Spacer()
                Text("\(Int(progress))%")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Theme.green)
            }
            progressBar
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.white.opacity(0.035))
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Theme.line, lineWidth: 1)
            }
        )
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.07))
                Capsule()
                    .fill(LinearGradient(colors: [Theme.green2, Theme.green],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(0, geo.size.width * CGFloat(progress / 100)))
                    .shadow(color: Theme.green.opacity(0.5), radius: 8)
            }
        }
        .frame(height: 6)
    }

    private var startButton: some View {
        Button(action: {
            guard isReady, !started else { return }
            withAnimation(.easeInOut(duration: 0.2)) { started = true }
        }) {
            Text(started ? "Started" : "Start")
                .font(.system(size: 15, weight: .heavy))
                .kerning(3)
                .foregroundColor(Theme.onGreen)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 19)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(LinearGradient(colors: [Theme.green, Theme.green2],
                                             startPoint: .top, endPoint: .bottom))
                )
        }
        .buttonStyle(StartButtonStyle())
        .disabled(!isReady || started)
        .opacity(isReady ? 1 : 0.35)
        .shadow(color: isReady ? Theme.green.opacity(0.35) : Color.clear,
                radius: 18, x: 0, y: 10)
    }

    private var telegramLink: some View {
        Link(destination: telegramURL) {
            HStack(spacing: 9) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 13, weight: .semibold))
                Text("t.me/ascentios")
                    .font(.system(size: 13, weight: .medium))
                    .kerning(0.4)
            }
            .foregroundColor(Theme.muted)
            .padding(.vertical, 11)
            .padding(.horizontal, 18)
            .background(
                ZStack {
                    Capsule().fill(Color.white.opacity(0.02))
                    Capsule().stroke(Theme.line, lineWidth: 1)
                }
            )
        }
    }

    // MARK: - Загрузка

    private func beginLoading() {
        guard timer == nil, !isReady else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { t in
            progress = min(100, progress + Double.random(in: 0.8...3.5))
            if progress >= 100 {
                progress = 100
                t.invalidate()
                timer = nil
            }
        }
    }
}

struct LoaderView_Previews: PreviewProvider {
    static var previews: some View {
        LoaderView().preferredColorScheme(.dark)
    }
}
