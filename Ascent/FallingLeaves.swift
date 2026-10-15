import SwiftUI

/// Осенние листья, которые падают поверх размытого фона.
/// Листья рисуются поверх размытия и падают с наклоном вправо.
struct FallingLeaves: View {
    @State private var time: Double = 0
    @State private var timer: Timer?

    private let count = 15

    private let colors: [Color] = [
        Theme.gold,
        Theme.goldSoft,
        Theme.amber,
        Theme.gold,
        Theme.rust,
        Theme.deepRust
    ]

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(0..<count, id: \.self) { index in
                    leaf(index, canvas: geo.size)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onAppear(perform: start)
        .onDisappear(perform: stop)
    }

    private func leaf(_ index: Int, canvas: CGSize) -> some View {
        let width = canvas.width
        let height = canvas.height

        let startX  = -0.05 + 0.72 * rnd(index, 1)      // старт левее
        let drift   = 0.16 + 0.30 * rnd(index, 10)      // снос вправо за время падения
        let speed   = 0.035 + 0.055 * rnd(index, 2)     // доля высоты в секунду
        let swayAmp = 8.0 + 22.0 * rnd(index, 3)
        let swayHz  = 0.18 + 0.42 * rnd(index, 4)
        let length  = 17.0 + 21.0 * rnd(index, 5)
        let spin    = 26.0 + 110.0 * rnd(index, 6)
        let phase   = rnd(index, 7) * 6.283
        let alpha   = 0.62 + 0.38 * rnd(index, 8)
        let tilt    = 16.0 + 26.0 * rnd(index, 11)      // наклон вправо
        let color   = colors[index % colors.count]

        let progress = (time * speed + rnd(index, 9)).truncatingRemainder(dividingBy: 1.0)
        let y = -70.0 + progress * (height + 140.0)
        let x = startX * width + drift * width * progress
                + sin(time * swayHz * 6.283 + phase) * swayAmp
        let angle = tilt + time * spin + phase * 30.0

        return LeafShape()
            .fill(color)
            .frame(width: length * 0.92, height: length)
            .rotationEffect(.degrees(angle))
            .shadow(color: Theme.deepRust.opacity(0.35), radius: 2.5, x: 0, y: 2)
            .opacity(alpha)
            .position(x: x, y: y)
    }

    private func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            time += 0.05
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Стабильное «случайное» число 0…1 для пары (лист, параметр).
    private func rnd(_ index: Int, _ key: Int) -> Double {
        let value = sin(Double(index) * 12.9898 + Double(key) * 78.233) * 43758.5453
        return value - value.rounded(.down)
    }
}

/// Мультяшный кленовый лист со стебельком.
struct LeafShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        func p(_ x: Double, _ y: Double) -> CGPoint {
            return CGPoint(x: w * CGFloat(x), y: h * CGFloat(y))
        }

        var path = Path()
        path.move(to: p(0.500, 0.000))
        path.addLine(to: p(0.585, 0.160))
        path.addLine(to: p(0.665, 0.115))
        path.addLine(to: p(0.700, 0.285))
        path.addLine(to: p(0.815, 0.270))
        path.addLine(to: p(0.760, 0.420))
        path.addLine(to: p(0.960, 0.510))
        path.addLine(to: p(0.760, 0.615))
        path.addLine(to: p(0.835, 0.765))
        path.addLine(to: p(0.640, 0.715))
        path.addLine(to: p(0.530, 0.870))
        path.addLine(to: p(0.545, 1.000))
        path.addLine(to: p(0.455, 1.000))
        path.addLine(to: p(0.470, 0.870))
        path.addLine(to: p(0.360, 0.715))
        path.addLine(to: p(0.165, 0.765))
        path.addLine(to: p(0.240, 0.615))
        path.addLine(to: p(0.040, 0.510))
        path.addLine(to: p(0.240, 0.420))
        path.addLine(to: p(0.185, 0.270))
        path.addLine(to: p(0.300, 0.285))
        path.addLine(to: p(0.335, 0.115))
        path.addLine(to: p(0.415, 0.160))
        path.closeSubpath()
        return path
    }
}
