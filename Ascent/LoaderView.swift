import SwiftUI

struct LoaderView: View {
    @StateObject private var state = LoaderState()

    private let panelHeight: CGFloat = 216

    var body: some View {
        // Один-единственный GeometryReader на весь экран. Всё остальное
        // расставляется СТАТИЧНЫМИ offset'ами: когда таскаешь меню или
        // квадратик, ничего в раскладке не меняется — перерисовывается
        // только то, что тащишь. Раньше тут были GeometryReader + .position,
        // и каждый кадр пересчитывался весь экран, от этого всё и залипало.
        GeometryReader { geo in
            let size = geo.size
            let top = max(geo.safeAreaInsets.top, 44)
            let bottom = max(geo.safeAreaInsets.bottom, 16)
            let panelWidth = min(size.width - 44, 300)

            ZStack(alignment: .topLeading) {
                // фон и дождь — статичные типы, их SwiftUI не перерисовывает
                BackdropView()

                RainView()
                    .allowsHitTesting(false)

                LoaderContent(state: state, topInset: top, bottomInset: bottom)

                // квадратик и меню живут, пока их не убрали кнопкой Exit:
                // unload останавливает лоадер, но НЕ прячет их
                if state.showing {
                    trigger(size: size, top: top, bottom: bottom)
                        .zIndex(3)

                    if state.menuOpen {
                        panel(size: size, top: top, bottom: bottom, width: panelWidth)
                            .zIndex(2)
                    }
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .ignoresSafeArea()
    }

    // MARK: - Квадратик мод-меню

    private func trigger(size: CGSize, top: CGFloat, bottom: CGFloat) -> some View {
        let side = MenuTrigger.side
        let baseX = size.width - side - 14
        let baseY = top + 14
        let area = CGRect(x: 10,
                          y: top + 10,
                          width: max(size.width - 20, 0),
                          height: max(size.height - top - bottom - 20, 0))

        return MenuTrigger(minX: area.minX - baseX,
                           maxX: max(area.maxX - side - baseX, area.minX - baseX),
                           minY: area.minY - baseY,
                           maxY: max(area.maxY - side - baseY, area.minY - baseY),
                           isOpen: state.menuOpen,
                           action: state.toggleMenu)
            .offset(x: baseX, y: baseY)
    }

    // MARK: - Меню

    private func panel(size: CGSize, top: CGFloat, bottom: CGFloat, width: CGFloat) -> some View {
        let baseX = (size.width - width) / 2
        // не по центру, а в свободной полосе под кнопкой Start,
        // чтобы сразу не закрывать Exit
        let baseY = size.height * 0.74 - panelHeight / 2
        let area = CGRect(x: 10,
                          y: top + 10,
                          width: max(size.width - 20, 0),
                          height: max(size.height - top - bottom - 20, 0))

        return MenuPanel(tab: $state.tab,
                         isRunning: state.running,
                         width: width,
                         height: panelHeight,
                         minX: area.minX - baseX,
                         maxX: max(area.maxX - width - baseX, area.minX - baseX),
                         minY: area.minY - baseY,
                         maxY: max(area.maxY - panelHeight - baseY, area.minY - baseY),
                         onClose: state.closeMenu,
                         onUnload: state.unload,
                         telegramURL: URL(string: "https://t.me/ascentios")!)
            .offset(x: baseX, y: baseY)
    }
}

// MARK: - Лоадер

private struct LoaderContent: View {
    @ObservedObject var state: LoaderState
    let topInset: CGFloat
    let bottomInset: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            Text("ascent")
                .font(.system(size: 46, weight: .heavy, design: .rounded))
                .foregroundColor(Theme.text)
                .shadow(color: Color.black.opacity(0.5), radius: 14, x: 0, y: 4)

            startButton
                .padding(.top, 40)

            Spacer(minLength: 0)

            telegramLink
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 24)
        .padding(.top, topInset)
        .padding(.bottom, bottomInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var startButton: some View {
        Button(action: state.tapStart) {
            Text(state.showing ? "Exit" : "Start")
                .font(.system(size: 15, weight: .heavy))
                .kerning(3)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 19)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(LinearGradient(colors: [Theme.grayTop, Theme.grayBottom],
                                             startPoint: .top, endPoint: .bottom))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Theme.grayLine, lineWidth: 1)
                )
        }
        .buttonStyle(StartButtonStyle())
        .shadow(color: Color.black.opacity(0.35), radius: 18, x: 0, y: 10)
    }

    private var telegramLink: some View {
        Link(destination: URL(string: "https://t.me/ascentios")!) {
            HStack(spacing: 9) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 13, weight: .semibold))
                Text("t.me/ascentios")
                    .font(.system(size: 13, weight: .medium))
                    .kerning(0.4)
            }
            .foregroundColor(.white)
            .padding(.vertical, 11)
            .padding(.horizontal, 18)
            .background(
                ZStack {
                    Capsule().fill(LinearGradient(colors: [Theme.grayTop, Theme.grayBottom],
                                                  startPoint: .top, endPoint: .bottom))
                    Capsule().stroke(Theme.grayLine, lineWidth: 1)
                }
            )
        }
    }
}

// MARK: - Фон

/// Статичный фон: свойств нет, поэтому SwiftUI его не перерисовывает,
/// когда таскаешь меню. Размытие впечатано в саму картинку.
private struct BackdropView: View {
    var body: some View {
        GeometryReader { geo in
            ZStack {
                Image("Backdrop")
                    .resizable()
                    .frame(width: geo.size.width, height: geo.size.height)

                Color.black.opacity(0.10)

                LinearGradient(colors: [Color.black.opacity(0.22), Color.clear, Color.black.opacity(0.38)],
                               startPoint: .top,
                               endPoint: .bottom)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
    }
}

struct LoaderView_Previews: PreviewProvider {
    static var previews: some View {
        LoaderView().preferredColorScheme(.dark)
    }
}
