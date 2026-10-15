import SwiftUI

/// Дождь. Капли падают строго вертикально.
///
/// Анимация сделана НЕ таймером (тот давал 20 кадров в секунду), а через
/// `repeatForever`: SwiftUI сам интерполирует значение каждый кадр экрана —
/// 60 Гц, а на ProMotion-экранах 120 Гц. Плюс всё рисуется одной фигурой,
/// поэтому накладных расходов почти нет.
struct RainView: View {
    @State private var phase: Double = 0

    /// Длительность полного цикла. Каждая капля за цикл пролетает экран
    /// целое число раз (cycles), поэтому стык цикла не виден.
    private let cycle: Double = 13.0

    var body: some View {
        ZStack {
            // дальний план: мелкая тусклая морось
            RainShape(phase: phase, count: 130, seed: 1,
                      cyclesMin: 5, cyclesMax: 9,
                      lengthMin: 7, lengthMax: 20,
                      widthMin: 0.9, widthMax: 1.4)
                .fill(Color(red: 0.80, green: 0.86, blue: 0.97))
                .opacity(0.16)

            RainShape(phase: phase, count: 62, seed: 2,
                      cyclesMin: 6, cyclesMax: 11,
                      lengthMin: 14, lengthMax: 36,
                      widthMin: 1.3, widthMax: 2.2)
                .fill(Color(red: 0.88, green: 0.93, blue: 1.0))
                .opacity(0.30)
        }
        // Рисуем одной прослойкой через Metal: кадры ровнее и дешевле.
        // Размытия тут больше нет — именно оно съедало кадры.
        .drawingGroup()
        .allowsHitTesting(false)
        .onAppear {
            phase = 0
            withAnimation(.linear(duration: cycle).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
    }
}

/// Все капли одним путём: X у каждой капли постоянный, поэтому дождь идёт
/// ровно вниз, без наклона и сноса в сторону.
struct RainShape: Shape {
    var phase: Double
    var count: Int
    var seed: Int
    var cyclesMin: Double
    var cyclesMax: Double
    var lengthMin: Double
    var lengthMax: Double
    var widthMin: Double
    var widthMax: Double

    /// Именно это значение SwiftUI плавно меняет от 0 до 1 каждый кадр.
    var animatableData: Double {
        get { phase }
        set { phase = newValue }
    }

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

            let x   = (a * 1.06 - 0.03) * w
            let len = lengthMin + (lengthMax - lengthMin) * b
            let lw  = widthMin + (widthMax - widthMin) * e

            // целое число пролётов за цикл — иначе на стыке будет рывок
            let cycles = (cyclesMin + (cyclesMax - cyclesMin) * c).rounded()
            let raw = phase * cycles + d
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
