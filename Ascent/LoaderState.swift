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

    /// Кнопка Start/Exit. Exit закрывает только лоадер — меню остаётся.
    func tapStart() {
        if running {
            stopLoader()
        } else {
            withAnimation(.easeInOut(duration: 0.18)) { running = true }
            withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) { menuOpen = true }
        }
    }

    func stopLoader() {
        withAnimation(.easeInOut(duration: 0.18)) { running = false }
    }

    func toggleMenu() {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) { menuOpen.toggle() }
    }

    func closeMenu() {
        withAnimation(.easeInOut(duration: 0.18)) { menuOpen = false }
    }
}
