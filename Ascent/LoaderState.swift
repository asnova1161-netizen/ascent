import SwiftUI
import UIKit
import Darwin

/// Состояние приложения: лоадер, оверлей и диагностика запуска HUD.
///
/// Квадрат и панель рисует отдельный HUD-процесс (он поверх всех приложений).
/// Это приложение только включает/выключает его и следит, жив ли он.
///
/// Главное правило: состояние кнопки Start/Exit определяется ТОЛЬКО тем, жив
/// ли HUD-процесс (PID-файл + kill(pid, 0)). Ни уход в фон, ни возврат в
/// приложение ничего не «сбрасывают» — они лишь перечитывают реальность.
final class LoaderState: ObservableObject {
    /// Лоадер «крутится». Меняется по Start / Exit / unload.
    @Published var running = false
    /// HUD-процесс подтверждённо жив. Это же значение решает, что показывает
    /// кнопка (Exit или Start) и прячем ли дубль квадрата внутри app.
    @Published var showing = false
    /// Пользователь нажал Start и ещё не нажал Exit. НЕ сбрасывается уходом в
    /// фон, сменой сцены или возвратом в приложение: пока оверлей включён,
    /// внутри app остаётся запасной квадратик.
    @Published var engaged = false
    /// Показывать ли отладочное окно.
    @Published var debugVisible = false
    /// Содержимое отладочного окна (обновляется раз в секунду).
    @Published var debugText = ""
    @Published var menuOpen = false
    @Published var tab = 0

    private var activationObserver: NSObjectProtocol?
    private var startupPollTimer: Timer?
    private var debugTimer: Timer?
    private var heartbeatTimer: Timer?
    private var isStarting = false

    init() {
        // Приложение могли перезапустить, пока оверлей уже висел, а из панели
        // оверлей могли погасить — просто перечитываем реальность.
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
        startupPollTimer?.invalidate()
        debugTimer?.invalidate()
        heartbeatTimer?.invalidate()
    }

    // MARK: - Кнопка Start / Exit

    /// Кнопка Start/Exit. Повторное нажатие во время запуска игнорируем.
    func tapStart() {
        if isStarting {
            return
        }
        if showing {
            stopHUD()
        } else {
            startHUD()
        }
    }

    private func startHUD() {
        isStarting = true
        running = true
        engaged = true
        menuOpen = false // после Start появляется ТОЛЬКО квадратик

        AscentHUDLogMessage("Swift: нажат Start")

        // Поднимаем HUD-процесс. Повторный Start дублей не создаёт (проверка
        // по PID-файлу внутри SetHUDEnabled).
        SetHUDEnabled(true)

        // Оверлей НЕ считаем запущенным, пока дочерний процесс не записал свой
        // PID и не оказался жив. До этого кнопка остаётся Start.
        waitForHUDStart()
    }

    /// Ждём до 3 секунд, пока HUD-процесс запишет PID-файл и окажется живым.
    private func waitForHUDStart() {
        startupPollTimer?.invalidate()

        let deadline = Date().addingTimeInterval(3.0)
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }

            if IsHUDEnabled() {
                timer.invalidate()
                self.startupPollTimer = nil
                self.isStarting = false
                self.showing = true
                self.running = true
                let pid = AscentHUDProcessID()
                AscentHUDLogMessage("Swift: оверлей подтверждён, pid=\(pid)")
                self.startHeartbeat()
                return
            }

            if Date() >= deadline {
                timer.invalidate()
                self.startupPollTimer = nil
                self.isStarting = false
                self.showing = false
                AscentHUDLogMessage("Swift: оверлей НЕ подтвердился за 3 с")
                // Показываем причину автоматически, чтобы не искать её вслепую.
                self.openDebug()
            }
        }

        RunLoop.main.add(timer, forMode: .common)
        startupPollTimer = timer
    }

    /// Exit: гасим HUD-процесс и снимаем состояние.
    private func stopHUD() {
        AscentHUDLogMessage("Swift: нажат Exit")
        startupPollTimer?.invalidate()
        startupPollTimer = nil
        stopHeartbeat()
        isStarting = false
        engaged = false
        running = false
        showing = false
        menuOpen = false
        SetHUDEnabled(false)
        refreshDebug()
    }

    /// Перечитываем реальность: жив ли HUD-процесс. Никаких других сбросов —
    /// уход в фон и возврат в приложение только это и пересчитывают.
    private func refreshFromProcess() {
        let alive = IsHUDEnabled()
        showing = alive
        if alive {
            startHeartbeat()
        } else {
            stopHeartbeat()
        }
        if debugVisible {
            refreshDebug()
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

    // MARK: - Пульс «HUD жив»

    /// Раз в 2 секунды отмечаем в журнале, что оверлей на связи. Если он умрёт,
    /// в журнале будет видно последнюю живую отметку и следующую за ней причину.
    private func startHeartbeat() {
        if heartbeatTimer != nil {
            return
        }
        let timer = Timer(timeInterval: 2.0, repeats: true) { _ in
            let pid = AscentHUDProcessID()
            let alive = IsHUDEnabled()
            AscentHUDLogMessage("HUD alive: pid=\(pid) жив=\(alive ? "да" : "нет")")
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer
    }

    private func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    // MARK: - Отладочное окно

    func toggleDebug() {
        if debugVisible {
            debugVisible = false
            debugTimer?.invalidate()
            debugTimer = nil
        } else {
            openDebug()
        }
    }

    func openDebug() {
        debugVisible = true
        refreshDebug()
        debugTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshDebug()
        }
        RunLoop.main.add(timer, forMode: .common)
        debugTimer = timer
    }

    func closeDebug() {
        debugVisible = false
        debugTimer?.invalidate()
        debugTimer = nil
    }

    private func refreshDebug() {
        debugText = buildDebugText()
    }

    private func buildDebugText() -> String {
        var lines: [String] = []

        let mode = AscentProcessMode() ?? "?"
        lines.append("режим процесса: \(mode)")
        lines.append("это -hud-процесс: \(mode == "-hud" ? "да" : "нет")")
        lines.append("")

        let spawnCode = AscentLastSpawnReturnCode()
        let spawnErrno = AscentLastSpawnErrno()
        lines.append("последний posix_spawn:")
        lines.append("  режим: \(AscentLastSpawnMode() ?? "?")")
        lines.append("  код возврата: \(spawnCode)\(spawnCode == 0 ? " (успех)" : " (ошибка)")")
        if let message = strerror(spawnErrno) {
            lines.append("  errno: \(spawnErrno) — \(String(cString: message))")
        } else {
            lines.append("  errno: \(spawnErrno)")
        }
        lines.append("  pid из spawn: \(AscentLastSpawnPID())")
        lines.append("")

        let pid = AscentHUDProcessID()
        let alive = IsHUDEnabled()
        lines.append("HUD-процесс:")
        lines.append("  PID-файл: \(pid > 0 ? "\(pid)" : "нет")")
        lines.append("  жив сейчас (kill pid 0): \(alive ? "да" : "нет")")
        lines.append("  кнопка показывает: \(showing ? "Exit" : "Start")")
        lines.append("")

        if let report = AscentProbeReport() {
            lines.append(report)
        }
        lines.append("")

        lines.append("entitlements из подписи бинарника:")
        if let entitlements = AscentOwnEntitlements(), !entitlements.isEmpty {
            lines.append(entitlements)
        } else {
            lines.append("  (не удалось прочитать)")
        }
        lines.append("")

        lines.append("последние 30 строк журнала:")
        lines.append(AscentHUDLogTail(30) ?? "")

        return lines.joined(separator: "\n")
    }
}
