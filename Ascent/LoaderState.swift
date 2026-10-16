import SwiftUI
import Darwin

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

    /// PID HUD-процесса, который мы запустили (0 — не запущен).
    private var hudPid: pid_t = 0

    private func startLoader() {
        running = true
        showing = true
        menuOpen = false       // после Start появляется ТОЛЬКО квадратик

        // На всякий случай гасим уже висящий HUD, чтобы не плодить окна.
        killHUD()

        // Запускаем HUD процесс
        let execURL = Bundle.main.executableURL
        guard let path = execURL?.path else { return }
        var pid: pid_t = 0
        var argv: [UnsafeMutablePointer<CChar>?] = [
            strdup(execURL?.lastPathComponent ?? "Ascent"),
            strdup("-hud"),
            nil
        ]
        let result = posix_spawn(&pid, path, nil, nil, &argv, nil)
        for arg in argv {
            if let arg = arg { free(arg) }
        }
        if result == 0 {
            hudPid = pid
        }
    }

    /// Всё убираем с экрана (это делает Exit).
    private func hideAll() {
        running = false
        showing = false
        menuOpen = false
        killHUD()
    }

    /// Гасит HUD-процесс.
    ///
    /// Мы сами его породили, поэтому просто шлём SIGKILL по сохранённому PID.
    /// Никаких внешних утилит вроде `killall` — в песочнице они недоступны,
    /// а сам HUD дополнительно завершается сам, когда умирает приложение
    /// (см. watchdog в HUDApp.mm).
    private func killHUD() {
        guard hudPid > 0 else { return }
        _ = kill(hudPid, SIGKILL)
        hudPid = 0
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
