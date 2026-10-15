import SwiftUI

struct LoaderView: View {
    @StateObject private var state = LoaderState()
    @State private var panelOffset: CGSize = .zero
    @State private var triggerOffset: CGSize = .zero

    private let panelHeight: CGFloat = 216

    var body: some View {
        ZStack {
            // фон и дождь — отдельные типы без изменяемых свойств, поэтому
            // при таскании меню SwiftUI их не перерисовывает
            BackdropView().ignoresSafeArea()

            RainView()
                .ignoresSafeArea()
                .allowsHitTesting(false)

            LoaderContent(state: state)

            // серая кнопка мод-меню: есть всегда, независимо от лоадера
            triggerLayer
                .zIndex(3)

            if state.menuOpen {
                menuLayer
                    .zIndex(2)
            }
        }
    }

    // MARK: - Кнопка мод-меню

    private var triggerLayer: some View {
        GeometryReader { geo in
            trigger(in: geo)
        }
        .ignoresSafeArea()
    }

    private func trigger(in geo: GeometryProxy) -> some View {
        let ins = geo.safeAreaInsets
        let half = MenuTrigger.side / 2
        let area = CGRect(x: ins.leading + 8,
                          y: ins.top + 8,
                          width: max(geo.size.width - ins.leading - ins.trailing - 16, 0),
                          height: max(geo.size.height - ins.top - ins.bottom - 16, 0))
        // по умолчанию — справа сверху, дальше её можно таскать
        let base = CGPoint(x: geo.size.width - ins.trailing - half - 14,
                           y: ins.top + half + 14)

        return MenuTrigger(offset: $triggerOffset,
                           minX: area.minX + half - base.x,
                           maxX: max(area.maxX - half - base.x, area.minX + half - base.x),
                           minY: area.minY + half - base.y,
                           maxY: max(area.maxY - half - base.y, area.minY + half - base.y),
                           isOpen: state.menuOpen,
                           action: state.toggleMenu)
            .position(x: base.x, y: base.y)
    }

    // MARK: - Меню

    private var menuLayer: some View {
        GeometryReader { geo in
            panel(in: geo)
        }
        .ignoresSafeArea()
    }

    private func panel(in geo: GeometryProxy) -> some View {
        let ins = geo.safeAreaInsets
        let panelWidth = min(geo.size.width - 44, 300)
        let baseX = (geo.size.width - panelWidth) / 2
        // Панель открывается не по центру, а в свободной полосе под кнопкой,
        // чтобы не закрывать Exit; дальше её можно таскать.
        let baseY = geo.size.height * 0.74 - panelHeight / 2

        // область, за которую панель не должна выходить
        let area = CGRect(x: ins.leading + 10,
                          y: ins.top + 10,
                          width: max(geo.size.width - ins.leading - ins.trailing - 20, 0),
                          height: max(geo.size.height - ins.top - ins.bottom - 20, 0))

        return MenuPanel(tab: $state.tab,
                         offset: $panelOffset,
                         width: panelWidth,
                         height: panelHeight,
                         minX: area.minX - baseX,
                         maxX: max(area.maxX - panelWidth - baseX, area.minX - baseX),
                         minY: area.minY - baseY,
                         maxY: max(area.maxY - panelHeight - baseY, area.minY - baseY),
                         onClose: state.closeMenu,
                         onUnload: state.stopLoader,
                         telegramURL: URL(string: "https://t.me/ascentios")!)
            .frame(width: panelWidth, height: panelHeight)
            .position(x: baseX + panelWidth / 2, y: baseY + panelHeight / 2)
            .transition(.scale(scale: 0.92, anchor: .center).combined(with: .opacity))
    }
}

// MARK: - Сам лоадер

/// Логотип, надпись, кнопка Start/Exit и ссылка.
/// Перерисовывается только при смене состояния лоадера — не при таскании меню.
private struct LoaderContent: View {
    @ObservedObject var state: LoaderState

    var body: some View {
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
        }
    }

    private var startButton: some View {
        Button(action: state.tapStart) {
            Text(state.running ? "Exit" : "Start")
                .font(.system(size: 15, weight: .heavy))
                .kerning(3)
                .foregroundColor(Theme.onGold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 19)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(LinearGradient(colors: state.running ? [Theme.amber, Theme.deepRust]
                                                                  : [Theme.gold, Theme.amber],
                                             startPoint: .top, endPoint: .bottom))
                )
        }
        .buttonStyle(StartButtonStyle())
        .shadow(color: Theme.amber.opacity(0.45), radius: 18, x: 0, y: 10)
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

// MARK: - Фон

/// Статичный фон. Отдельный тип без свойств: SwiftUI не перерисовывает его,
/// когда таскаешь меню. Размытие впечатано в саму картинку — в рантайме его
/// считать не нужно (раньше это делалось каждый кадр и всё заедало).
private struct BackdropView: View {
    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Фотка целиком и на весь экран: пропорции не сохраняем —
                // иначе либо обрезка, либо поля.
                Image("Backdrop")
                    .resizable()
                    .frame(width: geo.size.width, height: geo.size.height)

                Color.black.opacity(0.10)

                LinearGradient(
                    colors: [Color.black.opacity(0.22), Color.clear, Color.black.opacity(0.38)],
                    startPoint: .top,
                    endPoint: .bottom
                )
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
