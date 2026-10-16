import SwiftUI
import UIKit
import Darwin

/// Состояние приложения: лоадер и мод-меню.
///
/// Квадрат и панель теперь живут в отдельном HUD-процессе, который висит
/// поверх всех приложений. Этот объект только управляет им (Start/Exit) и
/// знает, поднят ли оверлей прямо сейчас.
final class LoaderState: ObservableObject {
    /// Лоадер «крутится». Меняется по Start / Exit / unload.
    @Published var running = false
    /// Оверлей вообще включён (кнопка показывает Exit вместо Start).
    @Published var showing = false
    /// HUD-процесс подтверждённо жив (по нему прячем дубль квадрата внутри app).
    @Published var hudRunning = false
    @Published var menuOpen = false
    @Published var tab = 0

    private var activationObserver: NSObjectProtocol?

    init() {
        // Приложение могли перезапустить, пока оверлей уже висел, а из панели
        // оверлей могли погасить — синхронизируемся при каждом возврате в app.
        activationObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshFromProcess()
        }

        // Синхронизацию делаем асинхронно: проверка состояния порождает
        // вспомогательный процесс, и не хочется тормозить первый кадр app.
        DispatchQueue.main.async { [weak self] in
            self?.refreshFromProcess()
        }
    }

    deinit {
        if let activationObserver = activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
    }

    /// Кнопка Start/Exit.
    func tapStart() {
        if showing { hideAll() } else { startLoader() }
    }

    private func startLoader() {
        running = true
        showing = true
        menuOpen = false // после Start появляется ТОЛЬКО квадратик

        // Поднимаем HUD-процесс. Повторный Start дублей не создаёт (проверка
        // по PID-файлу внутри SetHUDEnabled).
        SetHUDEnabled(true)
        // Считаем оверлей поднятым сразу: HUD-процессу нужно мгновение, чтобы
        // записать PID, и проверка «в лоб» успела бы вернуть false и мигнуть
        // лишним квадратом внутри приложения.
        hudRunning = true

        // Через секунду перепроверим по-настоящему: если HUD почему-то не
        // поднялся, покажем квадрат внутри app как запасной вариант.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self, self.showing else { return }
            self.hudRunning = IsHUDEnabled()
        }
    }

    /// Всё убираем с экрана (это делает Exit).
    private func hideAll() {
        running = false
        showing = false
        menuOpen = false
        SetHUDEnabled(false)
        hudRunning = false
    }

    private func refreshFromProcess() {
        let running = IsHUDEnabled()
        hudRunning = running
        showing = running
    }

    /// unload из меню: лоадер останавливается, но квадратик и меню
    /// ОСТАЮТСЯ на экране.
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
