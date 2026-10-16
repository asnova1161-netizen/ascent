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

    /// Куда панель уже утащили (сохраняется между перетаскиваниями).
    @State private var origin: CGSize = .zero
    /// Смещение текущего перетаскивания — живёт только пока палец на экране.
    ///
    /// Именно `@GestureState`, а не `@State`: SwiftUI сам обнуляет его, когда
    /// жест заканчивается ИЛИ отменяется, поэтому панель не залипает в
    /// сдвинутом положении, если жест перебили.
    @GestureState private var drag: CGSize = .zero

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
         telegramURL: URL) {
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
            if tab == 0 { mainTab } else { miscTab }
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
}
