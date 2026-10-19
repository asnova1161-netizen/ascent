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
    /// HUD-процесс поднялся И отрисовал свой UIKit-квадрат. Только тогда прячем
    /// запасной квадрат внутри app: пока это не так, квадрат живёт в приложении.
    @Published var hudOverlayReady = false
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
    /// Токен поколения запуска: каждое нажатие Start/Exit увеличивает счётчик.
    /// Фоновые блоки запуска и остановки берут его на входе и сверяют перед
    /// каждым важным шагом — так Exit мгновенно отменяет ещё поднимающийся
    /// HUD, а сторож остановки выходит, как только пользователь снова нажал
    /// Start (иначе он мог бы погасить УЖЕ новый оверлей).
    private var startGeneration = 0
    private var didFetchCrashLog = false

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

        // Метка начала запуска: если приложение упадёт между ней и меткой
        // «нажат Start»/«готово», в журнале останется видимый след.
        AscentHUDLogMessage("Swift: приложение запущено (pid=\(getpid()))")

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

    /// Кнопка Start/Exit. Показываем Exit по showing || engaged: engaged
    /// включается сразу при Start, поэтому кнопка переключается МГНОВЕННО,
    /// не дожидаясь PID-файла (тот появляется лишь через 1–2 с загрузки
    /// HUD-процесса). Exit во время запуска не игнорируется, а ОТМЕНЯЕТ его:
    /// stopHUD поднимает startGeneration, и незавершённый Start-блок сверху
    /// выходит, не дойдя до конца.
    func tapStart() {
        if showing || engaged {
            stopHUD()
        } else if !isStarting {
            startHUD()
        }
    }

    private func startHUD() {
        startGeneration += 1
        let generation = startGeneration
        isStarting = true
        running = true
        engaged = true
        menuOpen = false // после Start появляется ТОЛЬКО квадратик
        // Снимаем прошлую метку «HUD нарисовал квадрат»: новый процесс поставит
        // её сам, когда его оверлей реально поднимется. Иначе запасной квадрат
        // внутри app спрятался бы раньше времени.
        hudOverlayReady = false
        OverlayStore.setFlag(false, for: "hud.overlay")

        AscentHUDLogMessage("Swift: нажат Start")

        // Поднимаем HUD-процесс. Повторный Start дублей не создаёт (проверка
        // по PID-файлу внутри SetHUDEnabled).
        // Запуск делаем асинхронно, чтобы не блокировать основной поток
        // (спавн хелпера и файловые операции могут чуть подвисать на старых устройствах).
        DispatchQueue.global(qos: .userInitiated).async {
            SetHUDEnabled(true)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                // Запуск отменили (нажали Exit), пока хелпер поднимал HUD, —
                // дальше не идём: состояние уже сброшено в stopHUD.
                guard generation == self.startGeneration else {
                    AscentHUDLogMessage("Swift: Start отменён на этапе подъёма хелпера")
                    return
                }
                AscentHUDLogMessage("Swift: Start — HUD поднят, собираю диагностику")
                // Оверлей поднят — держим диагностику свежей всё время, пока он включён.
                self.refreshDebug()
                AscentHUDLogMessage("Swift: Start — диагностика собрана, жду PID-файл")
                self.startDiagnosticsRefresh()
                self.waitForHUDStart(generation: generation)
                AscentHUDLogMessage("Swift: Start — готово, показываю: \(self.showing || self.engaged ? "Exit" : "Start")")
            }
        }
        // Не блокируем UI: диагностика и ожидание продолжатся в фоне.
    }

    /// Ждём до 3 секунд, пока HUD-процесс запишет PID-файл и окажется живым.
    /// `generation` — токен запуска: если пользователь уже нажал Exit,
    /// таймер молча гаснет, ничего не перезаписывая.
    private func waitForHUDStart(generation: Int) {
        startupPollTimer?.invalidate()

        let deadline = Date().addingTimeInterval(3.0)
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            guard generation == self.startGeneration else {
                timer.invalidate()
                self.startupPollTimer = nil
                return
            }

            if IsHUDEnabled() {
                timer.invalidate()
                self.startupPollTimer = nil
                self.isStarting = false
                self.showing = true
                self.running = true
                // HUD пишет метку hud.overlay в момент создания своего квадрата;
                // к этому моменту PID-файл уже есть, а метка может появиться на
                // долю секунды позже. Перечитаем её чуть позже и в пульсе.
                // Быстрый опрос метки hud.overlay сразу после появления HUD,
                // чтобы окно двойного квадрата сократилось до минимума.
                let startWait = Date()
                let poll = Timer(timeInterval: 0.15, repeats: true) { [weak self] t in
                    guard let self = self else {
                        t.invalidate()
                        return
                    }
                    if OverlayStore.flag(for: "hud.overlay") || Date().timeIntervalSince(startWait) > 5.0 {
                        t.invalidate()
                        self.hudOverlayReady = IsHUDEnabled() && OverlayStore.flag(for: "hud.overlay")
                    }
                }
                RunLoop.main.add(poll, forMode: .common)
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
                // Запуск не удался — кнопка возвращается к Start.
                self.engaged = false
                AscentHUDLogMessage("Swift: оверлей НЕ подтвердился за 3 с")
            }
        }

        RunLoop.main.add(timer, forMode: .common)
        startupPollTimer = timer
    }

    /// Exit: гасим HUD-процесс и снимаем состояние.
    private func stopHUD() {
        AscentHUDLogMessage("Swift: нажат Exit")
        // Поднимаем токен: незавершённый Start-блок (если запуск ещё шёл)
        // увидит несовпадение и выйдет, не трогая состояние. Заодно сторож
        // остановки ниже выйдет, как только пользователь снова нажал Start.
        startGeneration += 1
        let generation = startGeneration
        startupPollTimer?.invalidate()
        startupPollTimer = nil
        stopHeartbeat()
        isStarting = false
        engaged = false
        running = false
        showing = false
        hudOverlayReady = false
        menuOpen = false
        refreshDebug()
        if !debugVisible {
            stopDiagnosticsRefresh()
        }
        // Делаем остановку HUD-процесса в фоне, чтобы кнопка
        // «Start/Exit» сразу перестала показывать Exit и не была с анимацией
        // с задержкой ~1 секунду из-за синхронного ожидания.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Сторож гонки «Exit до записи PID-файла»: если запуск ещё шёл,
            // PID-файл мог отсутствовать — тогда первый SetHUDEnabled(false)
            // ничего не погасил, и на пару секунд оставался живой оверлей.
            // Перепроверяем до 3 с (15 × 200 мс) и гасим повторно. Перед
            // КАЖДЫМ гашением сверяем токен: новый Start запрещает трогать
            // уже поднимающийся HUD.
            func killHUDIfStillWanted() -> Bool {
                guard let self = self, self.startGeneration == generation else {
                    return false
                }
                SetHUDEnabled(false)
                return true
            }
            guard killHUDIfStillWanted() else { return }
            for _ in 0..<15 {
                usleep(200_000)
                guard let self = self, self.startGeneration == generation else {
                    return
                }
                if !IsHUDEnabled() { break }
                SetHUDEnabled(false)
            }
            DispatchQueue.main.async { [weak self] in
                self?.refreshFromProcess()
            }
        }
    }

    /// Перечитываем реальность: жив ли HUD-процесс. Никаких других сбросов —
    /// уход в фон и возврат в приложение только это и пересчитывают.
    private func refreshFromProcess() {
        // Один раз за запуск подтягиваем системный отчёт Apple о падении
        // оверлея: там и тип исключения, и стек — причина видна сразу, без
        // разбора журнала вручную. Читает его root-хелпер (-crash).
        if !didFetchCrashLog {
            didFetchCrashLog = true
            AscentFetchSystemCrashReport()
        }

        let alive = IsHUDEnabled()
        showing = alive
        if !alive {
            hudOverlayReady = false
        } else if OverlayStore.flag(for: "hud.overlay") {
            // Метку ЗАПОМИНАЕМ: пока HUD жив, запасной квадрат и меню внутри app
            // больше не показываем. Раньше здесь стояло «alive && метка», и
            // любое мимолётное чтение метки=false возвращало запасную панель
            // ПРИЛОЖЕНИЯ поверх HUD: квадрат «телепортировался» на стартовую
            // позицию, а нажатия уходили в чужое меню.
            hudOverlayReady = true
        }
        if alive {
            // Оверлей уже поднят — значит мы «включены», даже если приложение
            // перезапускали: так кнопка, запасной квадрат и диагностика видят
            // одно и то же состояние.
            engaged = true
            startHeartbeat()
        } else {
            // Пока идёт запуск (isStarting), engaged НЕ сбрасываем: кнопка
            // уже показывает Exit, а PID-файл может просто ещё не появиться.
            // Если же HUD мёртв и запуска нет — кнопка возвращается к Start.
            if !isStarting {
                engaged = false
            }
            stopHeartbeat()
        }
        // Диагностику перечитываем всегда: она безопасна (никаких приватных
        // фреймворков) и нужна даже без открытого отладочного окна — по ней
        // видно, чем закончился предыдущий запуск.
        refreshDebug()
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
        // Как и в refreshFromProcess: пока HUD жив и метка хоть раз была true,
        // запасной квадрат/меню внутри app не возвращаем — иначе они на секунду
        // выскакивали поверх оверлея и «телепортировали» квадрат на место старта.
        if !alive {
            hudOverlayReady = false
        } else if OverlayStore.flag(for: "hud.overlay") {
            hudOverlayReady = true
        }
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
            }
            // Система пишет отчёт о падении с задержкой: если первый раз его
            // ещё не было, через несколько секунд он уже точно на месте.
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                guard let self = self else { return }
                AscentFetchSystemCrashReport()
                self.refreshDebug()
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
        // Причину падения оверлея точнее всего объясняет системный отчёт Apple,
        // а прочитать его может только root-хелпер — обновляем в момент разбора.
        AscentFetchSystemCrashReport()
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
            lines.append(logLines.suffix(40).joined(separator: "\n"))
        }

        return lines.joined(separator: "\n")
    }

    /// Короткая строка для панели внизу экрана: верхняя строка диагностики,
    /// то есть «ПРИЧИНА: …».
    var diagnosticsVerdict: String {
        debugText.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? ""
    }

    /// Последние шаги из журнала: по ним видно, до какой стадии дошёл HUD-процесс
    /// и до какой — само приложение. Стек падения сюда не попадает: у него
    /// отдельный блок, потому что важны первые кадры, а не последние.
    var diagnosticsSteps: String {
        let steps = debugText.split(separator: "\n")
            .map { stripLogPrefix($0.trimmingCharacters(in: .whitespaces)) }
            .filter {
                ($0.hasPrefix("[HUD]") && !$0.contains("!!! стек")) ||
                $0.hasPrefix("[crash]") ||
                $0.hasPrefix("!!!") ||
                $0.hasPrefix("Swift:")
            }
        return steps.suffix(6).joined(separator: "\n")
    }

    /// Стек падения HUD-процесса, если он был: где именно процесс упал, видно по
    /// первым кадрам. Пусто, если падения не было.
    var diagnosticsCrash: String {
        let frames = debugText.split(separator: "\n")
            .map { stripLogPrefix($0.trimmingCharacters(in: .whitespaces)) }
            .filter { $0.hasPrefix("[HUD] !!! стек") }
        return frames.prefix(9).joined(separator: "\n")
    }

    /// Признак того, что прошлый запуск приложения не дошёл до конца (упал).
    ///
    /// Метку «нажат Start» пишем до опасной работы, метку «готово» — после. Если
    /// в журнале есть первая и нет второй, значит между ними процесс умер — и
    /// причину надо показать сразу при запуске, не дожидаясь нажатий.
    var lastRunCrashed: Bool {
        let lines = debugText.split(separator: "\n")
            .map { stripLogPrefix($0.trimmingCharacters(in: .whitespaces)) }
        for line in lines.reversed() {
            if line.contains("Swift: Start — готово") || line.contains("Swift: нажат Exit") {
                return false
            }
            if line.contains("Swift: нажат Start") {
                return true
            }
        }
        return false
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
