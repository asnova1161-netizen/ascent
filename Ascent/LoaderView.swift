import SwiftUI

struct LoaderView: View {
    @State private var running = false
    @State private var menuOpen = false
    @State private var menuTab = 0
    @State private var panelOffset: CGSize = .zero
    @State private var triggerOffset: CGSize = .zero

    private let telegramURL = URL(string: "https://t.me/ascentios")!
    private let panelHeight: CGFloat = 216

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

            if running {
                triggerLayer
                    .zIndex(3)
            }

            if menuOpen {
                menuLayer
                    .zIndex(2)
            }
        }
    }

    // MARK: - Фон

    private var background: some View {
        GeometryReader { geo in
            ZStack {
                // Фотка целиком и на весь экран: пропорции не сохраняем —
                // иначе либо обрезка, либо поля.
                // Кадр чуть больше экрана (1.08), потому что размытие
                // осветляет края — так они остаются за пределами экрана.
                Image("Backdrop")
                    .resizable()
                    .frame(width: geo.size.width * 1.08, height: geo.size.height * 1.08)
                    .blur(radius: 2.5)

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

    // MARK: - Меню и кнопка мод-меню

    /// Серая кнопка мод-меню: появляется по Start, таскается по экрану,
    /// тап открывает и закрывает меню.
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
                           isOpen: menuOpen,
                           action: toggleMenu)
            .position(x: base.x, y: base.y)
            .transition(.scale.combined(with: .opacity))
    }

    // MARK: - Меню

    /// Плавающая панель: центр экрана плюс смещение, но не за краями.
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

        return MenuPanel(tab: $menuTab,
                         offset: $panelOffset,
                         width: panelWidth,
                         height: panelHeight,
                         minX: area.minX - baseX,
                         maxX: max(area.maxX - panelWidth - baseX, area.minX - baseX),
                         minY: area.minY - baseY,
                         maxY: max(area.maxY - panelHeight - baseY, area.minY - baseY),
                         onClose: { withAnimation(.easeInOut(duration: 0.18)) { menuOpen = false } },
                         onUnload: stop,
                         telegramURL: telegramURL)
            .frame(width: panelWidth, height: panelHeight)
            .position(x: baseX + panelWidth / 2, y: baseY + panelHeight / 2)
            .transition(.scale(scale: 0.92, anchor: .center).combined(with: .opacity))
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
        Button(action: { running ? stop() : start() }) {
            Text(running ? "Exit" : "Start")
                .font(.system(size: 15, weight: .heavy))
                .kerning(3)
                .foregroundColor(Theme.onGold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 19)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(LinearGradient(colors: running ? [Theme.amber, Theme.deepRust]
                                                             : [Theme.gold, Theme.amber],
                                             startPoint: .top, endPoint: .bottom))
                )
        }
        .buttonStyle(StartButtonStyle())
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

    // MARK: - Запуск и полное завершение

    private func start() {
        withAnimation(.easeInOut(duration: 0.18)) { running = true }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) { menuOpen = true }
    }

    /// Полностью закрыть: гасим загрузчик, меню и сбрасываем всё как было.
    private func stop() {
        withAnimation(.easeInOut(duration: 0.18)) {
            running = false
            menuOpen = false
        }
        menuTab = 0
        panelOffset = .zero
        triggerOffset = .zero
    }

    private func toggleMenu() {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
            menuOpen.toggle()
        }
    }
}

struct LoaderView_Previews: PreviewProvider {
    static var previews: some View {
        LoaderView().preferredColorScheme(.dark)
    }
}
