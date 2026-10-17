import SwiftUI

/// Плавающее меню мод-меню.
///
/// Панель непрозрачная (серая), текст белый. Таскается за шапку, за края
/// экрана не уходит: границы (minX…maxX, minY…maxY) считает родитель.
///
/// Смещение живёт ВНУТРИ панели: при перетаскивании перерисовывается только
/// она, а не весь экран с дождём — именно из-за этого раньше всё заедало.
struct MenuPanel: View {
    @Binding var tab: Int

    let isRunning: Bool
    let width: CGFloat
    let height: CGFloat
    let minX: CGFloat
    let maxX: CGFloat
    let minY: CGFloat
    let maxY: CGFloat

    let onClose: () -> Void
    let onUnload: () -> Void
    let telegramURL: URL

    /// Откуда стартует панель (читается из общего файла позиций оверлея).
    let initialOrigin: CGSize
    /// Куда панель утащили — чтобы сохранить это между запусками.
    let onOriginChange: (CGSize) -> Void

    /// Куда панель уже утащили (сохраняется между перетаскиваниями).
    @State private var origin: CGSize
    /// Смещение текущего перетаскивания — живёт только пока палец на экране.
    ///
    /// Именно `@GestureState`, а не `@State`: SwiftUI сам обнуляет его, когда
    /// жест заканчивается ИЛИ отменяется, поэтому панель не залипает в
    /// сдвинутом положении, если жест перебили.
    @GestureState private var drag: CGSize = .zero

    // Переключатели вкладки «game». Живут в общем файле оверлея, поэтому их
    // видит и HUD-процесс — именно он держит task-порт игры.
    @State private var espEnabled = false
    @State private var aimbotEnabled = false
    @State private var triggerbotEnabled = false
    @State private var aimFov: Double = 120
    @State private var aimSmooth: Double = 4
    @State private var triggerDelay: Double = 60
    @State private var gameProcessText = "проверить процесс игры"

    private let headerHeight: CGFloat = 44
    private let tabBarHeight: CGFloat = 40

    // серый фон непрозрачный + белый текст
    private let fill = Color(red: 0.145, green: 0.145, blue: 0.160)
    private let line = Color.white.opacity(0.12)
    private let dim  = Color.white.opacity(0.55)
    private let gray = Color(red: 0.36, green: 0.36, blue: 0.40)

    init(tab: Binding<Int>, isRunning: Bool,
         width: CGFloat, height: CGFloat,
         minX: CGFloat, maxX: CGFloat, minY: CGFloat, maxY: CGFloat,
         onClose: @escaping () -> Void, onUnload: @escaping () -> Void,
         telegramURL: URL,
         initialOrigin: CGSize = .zero,
         onOriginChange: @escaping (CGSize) -> Void = { _ in }) {
        self._tab = tab
        self.isRunning = isRunning
        self.width = width
        self.height = height
        self.minX = minX
        self.maxX = maxX
        self.minY = minY
        self.maxY = maxY
        self.onClose = onClose
        self.onUnload = onUnload
        self.telegramURL = telegramURL
        self.initialOrigin = initialOrigin
        self.onOriginChange = onOriginChange
        self._origin = State(initialValue: initialOrigin)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            tabBar
            content
        }
        .frame(width: width, height: height)
        // серый фон непрозрачный + белый текст
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous).fill(fill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(line, lineWidth: 1)
        )
        .contentShape(Rectangle())
        // ВАЖНО: жест и смещение — на ОДНОМ и том же вью (как в MenuTrigger).
        // Раньше жест висел на тексте «ascent», а offset — на внешнем VStack:
        // SwiftUI двигал один вью, а жест слушал другой, от этого панель
        // не ехала, а интерфейс подвешивался.
        .offset(x: position.width, y: position.height)
        .gesture(dragGesture)
    }

    // MARK: - Перетаскивание

    private var position: CGSize {
        clamp(CGSize(width: origin.width + drag.width,
                     height: origin.height + drag.height))
    }

    private func clamp(_ s: CGSize) -> CGSize {
        CGSize(width: min(max(s.width, minX), max(minX, maxX)),
               height: min(max(s.height, minY), max(minY, maxY)))
    }

    /// Перетаскивание за шапку.
    ///
    /// Жест и `.offset` живут на одном вью, поэтому во время движения
    /// перерисовывается только панель, а не весь экран. Смещение копится в
    /// `@GestureState` и обнуляется системой и при отпускании, и при отмене;
    /// в `onEnded` оно разово «затвердевает» в `origin`.
    ///
    /// Тянем только если палец опустился на шапку: касания по вкладкам
    /// main/misc, кнопкам внутри и по ссылке остаются им.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .updating($drag) { value, state, _ in
                if value.startLocation.y <= headerHeight {
                    state = value.translation
                }
            }
            .onEnded { value in
                guard value.startLocation.y <= headerHeight else { return }
                origin = clamp(CGSize(width: origin.width + value.translation.width,
                                      height: origin.height + value.translation.height))
                onOriginChange(origin)
            }
    }

    // MARK: - Шапка (за неё таскаем)

    private var header: some View {
        HStack(spacing: 10) {
            Text("ascent")
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .kerning(1.6)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(Color.white.opacity(0.85))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.white.opacity(0.10)))
                    .contentShape(Circle())
            }
        }
        .padding(.horizontal, 14)
        .frame(height: headerHeight)
        .overlay(Rectangle().fill(line).frame(height: 1), alignment: .bottom)
    }

    // MARK: - Вкладки

    private var tabBar: some View {
        HStack(spacing: 0) {
            tabButton("main", 0)
            tabButton("misc", 1)
            tabButton("game", 2)
        }
        .frame(height: tabBarHeight)
        .overlay(Rectangle().fill(line).frame(height: 1), alignment: .bottom)
    }

    private func tabButton(_ title: String, _ index: Int) -> some View {
        Button(action: { tab = index }) {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .kerning(0.6)
                    .foregroundColor(tab == index ? .white : dim)
                Rectangle()
                    .fill(tab == index ? Color.white : Color.clear)
                    .frame(height: 2)
                    .padding(.top, 7)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
    }

    // MARK: - Содержимое вкладок

    private var content: some View {
        Group {
            if tab == 0 { mainTab }
            else if tab == 1 { miscTab }
            else { gameTab }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
    }

    private var mainTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("статус")
                    .font(.system(size: 13))
                    .foregroundColor(dim)
                Spacer(minLength: 0)
                Text(isRunning ? "загрузчик активен" : "загрузчик остановлен")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
            }

            Link(destination: telegramURL) {
                HStack(spacing: 9) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Text("t.me/ascentios")
                        .font(.system(size: 13, weight: .medium))
                        .kerning(0.3)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Color.white.opacity(0.45))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.07))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(line, lineWidth: 1)
                )
            }
        }
    }

    private var miscTab: some View {
        VStack(spacing: 8) {
            Button(action: onUnload) {
                Text("unload")
                    .font(.system(size: 14, weight: .heavy))
                    .kerning(1.4)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(gray)
                    )
            }
            .buttonStyle(StartButtonStyle())

            Text("стоп лоадера, меню остаётся")
                .font(.system(size: 11.5))
                .foregroundColor(Color.white.opacity(0.5))
        }
    }

    // MARK: - Вкладка «game»

    private var gameTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("standoff 2")
                    .font(.system(size: 13))
                    .foregroundColor(dim)
                Spacer(minLength: 0)
                Text(espEnabled || aimbotEnabled || triggerbotEnabled ? "включено" : "выключено")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
            }

            cheatToggle(title: "esp", isOn: $espEnabled)
            cheatToggle(title: "aimbot", isOn: $aimbotEnabled)
            cheatToggle(title: "triggerbot", isOn: $triggerbotEnabled)

            cheatSlider(title: "fov", value: $aimFov, range: 20...400, suffix: "px")
            cheatSlider(title: "smooth", value: $aimSmooth, range: 1...20, suffix: "x")
            cheatSlider(title: "delay", value: $triggerDelay, range: 0...300, suffix: "мс")

            Button(action: refreshGameProcess) {
                Text(gameProcessText)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.75))
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(line, lineWidth: 1)
                    )
                    .contentShape(Rectangle())
            }

            Text("память игры читает HUD-процесс: переключатели выше только включают доступ к ней")
                .font(.system(size: 10.5))
                .foregroundColor(Color.white.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            loadCheatSettings()
            refreshGameProcess()
        }
    }

    private func cheatToggle(title: String, isOn: Binding<Bool>) -> some View {
        Button(action: {
            isOn.wrappedValue.toggle()
            saveCheatSettings()
        }) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                Spacer(minLength: 0)
                Text(isOn.wrappedValue ? "on" : "off")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(isOn.wrappedValue ? .white : dim)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(isOn.wrappedValue ? 0.14 : 0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(line, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
    }

    private func cheatSlider(title: String, value: Binding<Double>,
                             range: ClosedRange<Double>, suffix: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundColor(dim)
                Spacer(minLength: 0)
                Text("\(Int(value.wrappedValue))\(suffix)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
            }
            Slider(value: value, in: range, step: 1,
                   onEditingChanged: { _ in saveCheatSettings() },
                   label: { EmptyView() })
            .accentColor(.white)
        }
    }

    private func loadCheatSettings() {
        espEnabled = OverlayStore.flag(for: "cheat.esp")
        aimbotEnabled = OverlayStore.flag(for: "cheat.aimbot")
        triggerbotEnabled = OverlayStore.flag(for: "cheat.trigger")
        aimFov = OverlayStore.number(for: "cheat.fov", default: 120)
        aimSmooth = OverlayStore.number(for: "cheat.smooth", default: 4)
        triggerDelay = OverlayStore.number(for: "cheat.delay", default: 60)
    }

    private func saveCheatSettings() {
        OverlayStore.setFlag(espEnabled, for: "cheat.esp")
        OverlayStore.setFlag(aimbotEnabled, for: "cheat.aimbot")
        OverlayStore.setFlag(triggerbotEnabled, for: "cheat.trigger")
        OverlayStore.setNumber(aimFov, for: "cheat.fov")
        OverlayStore.setNumber(aimSmooth, for: "cheat.smooth")
        OverlayStore.setNumber(triggerDelay, for: "cheat.delay")
    }

    /// Проверяем, запущена ли игра. Это обычный sysctl-обход процессов —
    /// прав не требует, поэтому безопасно звать прямо из окна меню.
    private func refreshGameProcess() {
        let pid = AscentGameFindProcess("standoff")
        gameProcessText = pid > 0 ? "процесс: pid \(pid)" : "процесс не найден"
    }
}
