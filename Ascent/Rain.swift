import SwiftUI

/// Дождь. Капли падают строго вертикально (без наклона и без сноса в сторону).
/// Отрисовка — одной фигурой на слой, поэтому даже на старых устройствах плавно.
struct RainView: View {
    @State private var time: Double = 0
    @State private var timer: Timer?

    var body: some View {
        ZStack {
            // дальний план: мелкая и тусклая морось
            RainShape(time: time, count: 120, seed: 1, speedBase: 0.40,
                      lengthMin: 7, lengthMax: 20, widthMin: 0.6, widthMax: 1.1)
                .fill(Color(red: 0.80, green: 0.86, blue: 0.97))
                .opacity(0.15)

            // ближний план: длинные и заметные струи
            RainShape(time: time, count: 55, seed: 2, speedBase: 0.72,
                      lengthMin: 14, lengthMax: 36, widthMin: 1.0, widthMax: 1.8)
                .fill(Color(red: 0.88, green: 0.93, blue: 1.0))
                .opacity(0.30)
        }
        .allowsHitTesting(false)
        .onAppear {
            guard timer == nil else { return }
            let t = Timer(timeInterval: 0.05, repeats: true) { _ in
                time += 0.05
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }
}

/// Все капли одним путём: X у каждой капли постоянный, поэтому дождь идёт ровно вниз.
struct RainShape: Shape {
    var time: Double
    var count: Int
    var seed: Int
    var speedBase: Double
    var lengthMin: Double
    var lengthMax: Double
    var widthMin: Double
    var widthMax: Double

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        guard w > 0, h > 0 else { return path }

        for i in 0..<count {
            let a = rnd(i, 1)
            let b = rnd(i, 2)
            let c = rnd(i, 3)
            let d = rnd(i, 4)
            let e = rnd(i, 5)

            let x  = (a * 1.06 - 0.03) * w
            let len = lengthMin + (lengthMax - lengthMin) * b
            let speed = speedBase * (0.80 + 0.50 * c)
            let lw = widthMin + (widthMax - widthMin) * e

            let raw = time * speed + d
            let progress = raw - raw.rounded(.down)
            let y = progress * (h + len) - len

            path.addRoundedRect(in: CGRect(x: x, y: y, width: lw, height: len),
                                cornerSize: CGSize(width: lw / 2, height: lw / 2))
        }
        return path
    }

    /// Стабильное «случайное» число 0…1 для пары (капля, параметр).
    private func rnd(_ index: Int, _ key: Int) -> Double {
        let v = sin(Double(index) * 12.9898 + Double(key) * 78.233 + Double(seed) * 31.7) * 43758.5453
        return v - v.rounded(.down)
    }
}
