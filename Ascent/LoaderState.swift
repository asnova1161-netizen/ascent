import SwiftUI

/// Состояние приложения: лоадер, оверлей и диагностика запуска HUD.
///
/// Квадрат и панель рисует отдельный HUD-процесс (он поверх всех приложений).
/// Это приложение только включает/выключает его и следит, жив ли он.
final class LoaderState: ObservableObject {
    /// Лоадер «крутится». Меняется по Start / Exit / unload.
    @Published var running = false
    /// Оверлей вообще включён (кнопка показывает Exit вместо Start).
    @Published var showing = false
    /// HUD-процесс подтверждённо жив (по нему прячем дубль квадрата внутри app).
    @Published var hudRunning = false
    /// Журнал запуска HUD. Не nil — значит оверлей не поднялся и надо показать,
    /// на чём именно он споткнулся.
    @Published var hudLog: String?
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

        // Синхронизацию делаем асинхронно, чтобы не тормозить первый кадр app.
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

        AscentHUDLogMessage("Swift: нажат Start")

        // Поднимаем HUD-процесс. Повторный Start дублей не создаёт (проверка
        // по PID-файлу внутри SetHUDEnabled).
        SetHUDEnabled(true)
        // Считаем оверлей поднятым сразу: HUD-процессу нужно мгновение, чтобы
        // записать PID, и проверка «в лоб» успела бы вернуть false и мигнуть
        // лишним квадратом внутри приложения.
        hudRunning = true
        hudLog = nil

        // Через полтора секунды перепроверим по-настоящему: если HUD почему-то
        // не поднялся, покажем квадрат внутри app и журнал с причиной.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self, self.showing else { return }

            let alive = IsHUDEnabled()
            self.hudRunning = alive
            self.hudLog = alive ? nil : AscentHUDLogText()
        }
    }

    /// Всё убираем с экрана (это делает Exit).
    private func hideAll() {
        AscentHUDLogMessage("Swift: нажат Exit")
        running = false
        showing = false
        menuOpen = false
        SetHUDEnabled(false)
        hudRunning = false
        hudLog = nil
    }

    private func refreshFromProcess() {
        let running = IsHUDEnabled()
        hudRunning = running
        showing = running
        if running {
            hudLog = nil
        }
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
