import SwiftUI

struct LoaderView: View {
    @State private var started = false

    private let telegramURL = URL(string: "https://t.me/ascentios")!

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

                startButton
                    .padding(.top, 40)

                Spacer(minLength: 0)

                telegramLink
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 24)
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

    private var startButton: some View {
        Button(action: {
            guard !started else { return }
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
        .disabled(started)
        .shadow(color: Theme.green.opacity(0.35), radius: 18, x: 0, y: 10)
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
}

struct LoaderView_Previews: PreviewProvider {
    static var previews: some View {
        LoaderView().preferredColorScheme(.dark)
    }
}
