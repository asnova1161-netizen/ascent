import SwiftUI
import UIKit

/// Дождь.
///
/// Раньше капли пересчитывались и перерисовывались заново каждый кадр, и как
/// только начинаешь что-то двигать (меню, квадратик) — кадров переставало
/// хватать, всё залипало.
///
/// Теперь дождь рисуется ОДИН раз в картинки-плитки, а дальше их просто
/// прокручивает Core Animation — на стороне системы, вообще без участия
/// приложения. Главный поток при этом свободен: таскай меню сколько хочешь.
struct RainView: UIViewRepresentable {
    func makeUIView(context: Context) -> RainUIView { RainUIView() }
    func updateUIView(_ uiView: RainUIView, context: Context) { }
}

/// Слой дождя: свой набор капель, который прокручивается одной картинкой.
private struct RainLevel {
    let seed: Int
    let parity: Int            // 0 / 1 — какие капли берём (чётные или нечётные)
    let count: Int             // сколько всего капель в этом плане
    let lengthMin: CGFloat
    let lengthMax: CGFloat
    let widthMin: CGFloat
    let widthMax: CGFloat
    let color: UIColor
    let alpha: CGFloat
    let cycles: Double         // пролётов экрана за 13 секунд
}

final class RainUIView: UIView {
    /// Было раньше: полный проход экрана за 13 секунд. Сохраняем ту же скорость.
    private let referenceCycle: Double = 13

    /// Высота плитки. Меньше экрана — узор повторяется, но для дождя это
    /// незаметно, зато памяти уходит в разы меньше.
    private let tileHeight: CGFloat = 520

    private let levels: [RainLevel] = [
        // дальний план: мелкая тусклая морось, две скорости
        RainLevel(seed: 1, parity: 0, count: 104, lengthMin: 7, lengthMax: 20,
                  widthMin: 0.9, widthMax: 1.4,
                  color: UIColor(red: 0.80, green: 0.86, blue: 0.97, alpha: 1), alpha: 0.16,
                  cycles: 6.2),
        RainLevel(seed: 1, parity: 1, count: 104, lengthMin: 7, lengthMax: 20,
                  widthMin: 0.9, widthMax: 1.4,
                  color: UIColor(red: 0.80, green: 0.86, blue: 0.97, alpha: 1), alpha: 0.16,
                  cycles: 8.8),
        // ближний план: крупнее и ярче, тоже две скорости
        RainLevel(seed: 2, parity: 0, count: 50, lengthMin: 14, lengthMax: 36,
                  widthMin: 1.3, widthMax: 2.2,
                  color: UIColor(red: 0.88, green: 0.93, blue: 1.0, alpha: 1), alpha: 0.30,
                  cycles: 7.0),
        RainLevel(seed: 2, parity: 1, count: 50, lengthMin: 14, lengthMax: 36,
                  widthMin: 1.3, widthMax: 2.2,
                  color: UIColor(red: 0.88, green: 0.93, blue: 1.0, alpha: 1), alpha: 0.30,
                  cycles: 10.0)
    ]

    private var built = false
    private var scrolls: [(layer: CALayer, duration: Double)] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        layer.masksToBounds = true
        // система убирает анимации, когда приложение уходит в фон — вернём их
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(wake),
                                               name: UIApplication.didBecomeActiveNotification,
                                               object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !built, bounds.width > 1, bounds.height > 1 else { return }
        built = true
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 2
        for level in levels { add(level: level, scale: scale) }
    }

    @objc private func wake() {
        for item in scrolls where item.layer.animation(forKey: "rain") == nil {
            item.layer.add(scrollAnimation(duration: item.duration), forKey: "rain")
        }
    }

    // MARK: - Слои

    private func add(level: RainLevel, scale: CGFloat) {
        // плотность капель как раньше: на экран высотой bounds.height
        // приходилось count капель — значит на плитку нужно пропорционально
        let ratio = Double(tileHeight / max(bounds.height, 1))
        let drops = max(Int((Double(level.count) * ratio / 2).rounded()), 1)
        guard let tile = makeTile(level: level, drops: drops, scale: scale) else { return }

        let copies = Int(ceil(bounds.height / tileHeight)) + 2

        let scroll = CALayer()
        scroll.anchorPoint = CGPoint(x: 0, y: 0)
        scroll.position = CGPoint(x: 0, y: 0)
        scroll.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: tileHeight * CGFloat(copies))
        scroll.masksToBounds = true

        for i in 0..<copies {
            let copy = CALayer()
            copy.contents = tile
            copy.contentsScale = scale
            copy.contentsGravity = .resize
            copy.frame = CGRect(x: 0, y: tileHeight * CGFloat(i), width: bounds.width, height: tileHeight)
            scroll.addSublayer(copy)
        }

        let speed = speed(level: level)                 // точек в секунду
        let duration = Double(tileHeight / max(speed, 1))
        scroll.add(scrollAnimation(duration: duration), forKey: "rain")
        layer.addSublayer(scroll)
        scrolls.append((layer: scroll, duration: duration))
    }

    private func scrollAnimation(duration: Double) -> CABasicAnimation {
        let anim = CABasicAnimation(keyPath: "transform.translation.y")
        anim.fromValue = 0
        anim.toValue = -tileHeight
        anim.duration = duration
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .linear)
        anim.isRemovedOnCompletion = false
        return anim
    }

    private func speed(level: RainLevel) -> CGFloat {
        let avgLen = (level.lengthMin + level.lengthMax) / 2
        return CGFloat(level.cycles * Double(bounds.height + avgLen) / referenceCycle)
    }

    // MARK: - Картинка-плитка

    private func makeTile(level: RainLevel, drops: Int, scale: CGFloat) -> CGImage? {
        let pxW = Int((bounds.width * scale).rounded())
        let pxH = Int((tileHeight * scale).rounded())
        guard pxW > 0, pxH > 0 else { return nil }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false

        let w = CGFloat(pxW)
        let h = CGFloat(pxH)
        let paint = level.color.withAlphaComponent(level.alpha)

        let image = UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format).image { _ in
            paint.setFill()
            for j in 0..<drops {
                // чётные капли — в один слой, нечётные — в другой: вместе они
                // дают ровно тот же рисунок, что был раньше
                let i = level.parity + j * 2
                let a = rnd(i, 1, level.seed)
                let b = rnd(i, 2, level.seed)
                let d = rnd(i, 4, level.seed)
                let e = rnd(i, 5, level.seed)

                let x = (a * 1.06 - 0.03) * w
                let len = (level.lengthMin + (level.lengthMax - level.lengthMin) * b) * scale
                let lw = (level.widthMin + (level.widthMax - level.widthMin) * e) * scale
                let y = d * h

                let rect = CGRect(x: x, y: y, width: lw, height: len)
                UIBezierPath(roundedRect: rect, cornerRadius: lw / 2).fill()

                // капля на стыке плиток дорисовывается сверху — иначе на стыке
                // будет видна обрезанная капля
                if y + len > h {
                    UIBezierPath(roundedRect: rect.offsetBy(dx: 0, dy: -h),
                                 cornerRadius: lw / 2).fill()
                }
            }
        }
        return image.cgImage
    }

    /// Стабильное «случайное» число 0…1 — та же формула, что и в прежнем дожде.
    private func rnd(_ index: Int, _ key: Int, _ seed: Int) -> CGFloat {
        let v = sin(Double(index) * 12.9898 + Double(key) * 78.233 + Double(seed) * 31.7) * 43758.5453
        return CGFloat(v - v.rounded(.down))
    }
}
