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
}
