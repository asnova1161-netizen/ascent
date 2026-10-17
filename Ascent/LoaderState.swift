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
        // Оверлей поднят — держим диагностику свежей всё время, пока он включён:
        // её короткая версия висит внизу экрана, а не только в отдельном окне.
        refreshDebug()
        startDiagnosticsRefresh()

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
        if !debugVisible {
            stopDiagnosticsRefresh()
        }
    }

    /// Перечитываем реальность: жив ли HUD-процесс. Никаких других сбросов —
    /// уход в фон и возврат в приложение только это и пересчитывают.
    private func refreshFromProcess() {
        let alive = IsHUDEnabled()
        showing = alive
        if alive {
            // Оверлей уже поднят — значит мы «включены», даже если приложение
            // перезапускали: так кнопка, запасной квадрат и диагностика видят
            // одно и то же состояние.
            engaged = true
            startHeartbeat()
        } else {
            stopHeartbeat()
        }
        if debugVisible || engaged {
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
    private func heartbeat(_ timer: Timer) {
        let pid = AscentHUDProcessID()
        let alive = IsHUDEnabled()
        AscentHUDLogMessage("HUD alive: pid=\(pid) жив=\(alive ? "да" : "нет")")

        // HUD пропал — отмечаем это один раз и прекращаем пульс, чтобы журнал
        // не забивался одинаковыми строками (и интерфейс не тормозил).
        if !alive {
            timer.invalidate()
            heartbeatTimer = nil
            AscentHUDLogMessage("HUD пропал — возвращаем квадрат внутрь приложения")
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.refreshFromProcess()
                // Чтобы не искать причину вслепую: как только оверлей пропал,
                // сразу показываем отладочное окно с выводом «ПРИЧИНА».
                self.openDebug()
            }
        }
    }

    private func startHeartbeat() {
        if heartbeatTimer != nil {
            return
        }
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] timer in
            self?.heartbeat(timer)
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
            closeDebug()
        } else {
            openDebug()
        }
    }

    func openDebug() {
        debugVisible = true
        refreshDebug()
        startDiagnosticsRefresh()
    }

    func closeDebug() {
        // Окно просто прячем: пока оверлей включён, диагностика продолжает
        // обновляться — её короткая строка висит внизу экрана.
        debugVisible = false
    }

    /// Раз в 2 секунды пересчитываем диагностику: чаще не нужно, а на iPhone 7
    /// лишняя работа заметна.
    private func startDiagnosticsRefresh() {
        if debugTimer != nil {
            return
        }
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshDebug()
        }
        RunLoop.main.add(timer, forMode: .common)
        debugTimer = timer
    }

    private func stopDiagnosticsRefresh() {
        debugTimer?.invalidate()
        debugTimer = nil
    }

    private func refreshDebug() {
        debugText = buildDebugText()
    }

    private func buildDebugText() -> String {
        var lines: [String] = []

        let spawnCode = AscentLastSpawnReturnCode()
        let logTail = AscentHUDLogTail(80) ?? ""
        let logLines = logTail.split(separator: "\n", omittingEmptySubsequences: false)
        let processState = AscentHUDProcessState() ?? "состояние неизвестно"

        // Самое главное — короткий вывод о причине: его легко переписать или
        // продиктовать, не разбираясь в остальном тексте.
        lines.append("ПРИЧИНА: \(verdict(logText: logTail, spawnCode: spawnCode, processState: processState))")
        lines.append("")

        let mode = AscentProcessMode() ?? "?"
        lines.append("режим процесса: \(mode)")
        lines.append("это -hud-процесс: \(mode == "-hud" ? "да" : "нет")")
        lines.append("")

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
        lines.append("  состояние: \(processState)")
        lines.append("  kill(pid, 0) говорит жив: \(alive ? "да" : "нет")")
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
        if logLines.isEmpty {
            lines.append("(журнал пуст)")
        } else {
            lines.append(logLines.suffix(30).joined(separator: "\n"))
        }

        return lines.joined(separator: "\n")
    }

    /// Короткая строка для панели внизу экрана: верхняя строка диагностики,
    /// то есть «ПРИЧИНА: …».
    var diagnosticsVerdict: String {
        debugText.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? ""
    }

    /// Последние шаги HUD-процесса из журнала: по ним видно, до какой стадии он
    /// дошёл (инициализация, окно, хостинг).
    var diagnosticsSteps: String {
        let steps = debugText.split(separator: "\n")
            .map { stripLogPrefix($0.trimmingCharacters(in: .whitespaces)) }
            .filter { $0.hasPrefix("[HUD]") || $0.hasPrefix("!!!") }
        return steps.suffix(6).joined(separator: "\n")
    }

    /// Короткий вывод: что именно случилось с оверлеем.
    private func verdict(logText: String, spawnCode: Int32, processState: String) -> String {
        if spawnCode != 0 {
            let message = strerror(spawnCode).map { String(cString: $0) } ?? "неизвестно"
            return "posix_spawn не прошёл: errno \(spawnCode) — \(message)"
        }

        let lines = logText.split(separator: "\n").map { stripLogPrefix(String($0)) }
        let hudLines = lines.filter { $0.hasPrefix("[HUD]") }

        for line in lines.reversed() {
            if line.contains("убит сигналом") {
                return "HUD-процесс убит: \(line)"
            }
            if line.contains("завершился сам, код") {
                return "HUD-процесс завершился сам: \(line)"
            }
        }

        if processState.contains("ЗОМБИ") {
            if let last = hudLines.last {
                return "HUD-процесс УЖЕ ЗАВЕРШИЛСЯ (зомби), последний шаг — \(last)"
            }
            return "HUD-процесс УЖЕ ЗАВЕРШИЛСЯ (зомби) и в журнал ничего не записал"
        }

        if hudLines.isEmpty {
            return "HUD-процесс не записал в журнал ни одной строки — он не дошёл до старта"
        }

        if let last = hudLines.last {
            if last.contains("delegate:") || last.contains("rootVC:") {
                return "процесс жив и дошёл до окна, значит окно не выводится поверх: \(last)"
            }
            return "HUD-процесс \(processState), последний шаг — \(last)"
        }
        return "неизвестно"
    }

    /// Убирает из строки журнала дату и «[pid uid=N] », оставляя суть.
    private func stripLogPrefix(_ line: String) -> String {
        if let range = line.range(of: "] ") {
            return String(line[range.upperBound...])
        }
        return line
    }
}
