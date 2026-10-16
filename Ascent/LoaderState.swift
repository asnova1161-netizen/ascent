import SwiftUI

/// Состояние приложения: лоадер и мод-меню.
///
/// Отдельный объект, а не поля прямо во View: благодаря этому SwiftUI не
/// перерисовывает тяжёлые статичные слои (фон, дождь, лоадер), когда мы
/// таскаем меню или кнопку — от этого всё заедало.
final class LoaderState: ObservableObject {
    /// Загрузчик работает. Меняется по Start / Exit / unload.
    @Published var running = false
    /// Квадратик и меню вообще есть на экране (Start включает, Exit убирает).
    @Published var showing = false
    @Published var menuOpen = false
    @Published var tab = 0

    /// Кнопка Start/Exit.
    ///
    /// Start: лоадер пошёл, вылез квадратик и открылось меню.
    /// Exit: лоадер встал, и меню вместе с квадратиком пропали —
    /// вернуть их можно только новым Start.
    func tapStart() {
        if showing { hideAll() } else { startLoader() }
    }

    private func startLoader() {
        running = true
        showing = true
        menuOpen = false       // после Start появляется ТОЛЬКО квадратик
    }

    /// Всё убираем с экрана (это делает Exit).
    private func hideAll() {
        running = false
        showing = false
        menuOpen = false
    }

    /// unload из меню: лоадер останавливается, но квадратик и меню
    /// ОСТАЮТСЯ на экране — чтобы можно было запустить снова или потаскать.
    func unload() {
        running = false
    }

    func toggleMenu() {
        menuOpen.toggle()
    }

    func closeMenu() {
        menuOpen = false
    }
}
