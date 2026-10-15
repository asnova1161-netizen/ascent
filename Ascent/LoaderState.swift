import SwiftUI

/// Состояние приложения: лоадер и мод-меню.
///
/// Отдельный объект, а не поля прямо во View: благодаря этому SwiftUI не
/// перерисовывает тяжёлые статичные слои (фон, дождь, лоадер), когда мы
/// таскаем меню или кнопку — от этого всё заедало.
final class LoaderState: ObservableObject {
    @Published var running = false      // загрузчик работает (Start / Exit)
    @Published var menuOpen = false
    @Published var tab = 0

    /// Выключатель мод-меню: до первого Start ни кнопки, ни меню нет.
    /// Нажал Start — квадратик появился и дальше остаётся на экране.
    @Published var armed = false

    /// Кнопка Start/Exit.
    ///
    /// Start: лоадер пошёл, вылез квадратик и открылось меню.
    /// Exit или unload: лоадер встал и меню закрылось вместе с ним.
    func tapStart() {
        if running { stopLoader() } else { startLoader() }
    }

    private func startLoader() {
        armed = true
        withAnimation(.easeInOut(duration: 0.18)) { running = true }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) { menuOpen = true }
    }

    func stopLoader() {
        withAnimation(.easeInOut(duration: 0.18)) {
            running = false
            menuOpen = false
        }
    }

    func toggleMenu() {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) { menuOpen.toggle() }
    }

    func closeMenu() {
        withAnimation(.easeInOut(duration: 0.18)) { menuOpen = false }
    }
}
