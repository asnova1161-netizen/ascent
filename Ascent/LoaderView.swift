import SwiftUI

struct LoaderView: View {
    @State private var started = false

    private let telegramURL = URL(string: "https://t.me/ascentios")!

    var body: some View {
        ZStack {
            background.ignoresSafeArea()

            RainView()
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                logoMark

                Text("ascent")
                    .font(.system(size: 46, weight: .heavy, design: .rounded))
                    .foregroundColor(Theme.text)
                    .shadow(color: Color.black.opacity(0.5), radius: 14, x: 0, y: 4)
                    .padding(.top, 26)

                startButton
                    .padding(.top, 40)

                Spacer(minLength: 0)

                telegramLink
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
        }
    }

    // MARK: - Фон

    private var background: some View {
        GeometryReader { geo in
            ZStack {
                Image("OctoberBG")
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width * 1.15, height: geo.size.height * 1.15)
                    .blur(radius: 8)

                Color.black.opacity(0.16)

                LinearGradient(
                    colors: [Color.black.opacity(0.22), Color.clear, Color.black.opacity(0.40)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
    }

    // MARK: - Части экрана

    private var logoMark: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(colors: [Theme.gold.opacity(0.18), Color.white.opacity(0.02)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 72, height: 72)
                .shadow(color: Theme.amber.opacity(0.35), radius: 22, x: 0, y: 14)

            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Theme.line, lineWidth: 1)
                .frame(width: 72, height: 72)

            Image(systemName: "arrow.up")
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(Theme.gold)
                .shadow(color: Theme.gold.opacity(0.6), radius: 8)
        }
    }

    private var startButton: some View {
        Button(action: {
            guard !started else { return }
            withAnimation(.easeInOut(duration: 0.2)) { started = true }
        }) {
            Text(started ? "Started" : "Start")
                .font(.system(size: 15, weight: .heavy))
                .kerning(3)
                .foregroundColor(Theme.onGold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 19)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(LinearGradient(colors: [Theme.gold, Theme.amber],
                                             startPoint: .top, endPoint: .bottom))
                )
        }
        .buttonStyle(StartButtonStyle())
        .disabled(started)
        .shadow(color: Theme.amber.opacity(0.45), radius: 18, x: 0, y: 10)
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
                    Capsule().fill(Theme.gold.opacity(0.10))
                    Capsule().stroke(Theme.line, lineWidth: 1)
                }
            )
        }
    }
}

struct LoaderView_Previews: PreviewProvider {
    static var previews: some View {
        LoaderView().preferredColorScheme(.dark)
    }
}
