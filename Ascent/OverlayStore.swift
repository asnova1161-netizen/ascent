import SwiftUI
import Foundation
import Darwin

/// Общие позиции квадрата и панели оверлея.
///
/// HUD-процесс бежит от root и его контейнер отличается от контейнера
/// приложения, поэтому файл лежит в каталоге, который главный процесс
/// передал HUD-процессу аргументом (см. `AscentStateDirectory`).
enum OverlayStore {
    private static let fileName = "ascent.overlay.plist"

    private static var fileURL: URL {
        URL(fileURLWithPath: AscentStateDirectory()).appendingPathComponent(fileName)
    }

    private static func load() -> [String: Double] {
        guard let dict = NSDictionary(contentsOf: fileURL) as? [String: Any] else {
            return [:]
        }
        var out: [String: Double] = [:]
        for (key, value) in dict {
            if let number = value as? NSNumber {
                out[key] = number.doubleValue
            } else if let doubleValue = value as? Double {
                out[key] = doubleValue
            }
        }
        return out
    }

    private static func save(_ values: [String: Double]) {
        let dictionary = values as NSDictionary
        if dictionary.write(toFile: fileURL.path, atomically: true) {
            // Файл мог быть создан root'ом — даём возможность писать и мобильному
            // процессу приложения.
            _ = chmod(fileURL.path, 0o666)
        }
    }

    static func origin(for key: String) -> CGSize {
        let values = load()
        guard let x = values[key + ".x"], let y = values[key + ".y"] else {
            return .zero
        }
        return CGSize(width: x, height: y)
    }

    static func setOrigin(_ size: CGSize, for key: String) {
        var values = load()
        values[key + ".x"] = Double(size.width)
        values[key + ".y"] = Double(size.height)
        save(values)
    }

    // MARK: - Настройки игровых функций

    /// Числовая настройка. Хранится в том же общем файле, поэтому HUD-процесс
    /// (он бежит от root) видит переключатели меню без всякой связи между
    /// процессами.
    static func number(for key: String, default defaultValue: Double = 0) -> Double {
        return load()[key] ?? defaultValue
    }

    static func setNumber(_ value: Double, for key: String) {
        var values = load()
        values[key] = value
        save(values)
    }

    static func flag(for key: String, default defaultValue: Bool = false) -> Bool {
        return number(for: key, default: defaultValue ? 1 : 0) > 0.5
    }

    static func setFlag(_ value: Bool, for key: String) {
        setNumber(value ? 1 : 0, for: key)
    }
}
