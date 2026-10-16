import SwiftUI

/// Серая плавающая кнопка мод-меню.
///
/// Таскается по всему экрану (границы считает родитель), обычный тап
/// открывает и закрывает меню. Смещение живёт внутри кнопки — при
/// перетаскивании перерисовывается только она, а не весь экран.
struct MenuTrigger: View {
    let minX: CGFloat
    let maxX: CGFloat
    let minY: CGFloat
    let maxY: CGFloat
    let isOpen: Bool
    let action: () -> Void

    static let side: CGFloat = 54

    /// Куда кнопку уже утащили (сохраняется между перетаскиваниями).
    @State private var origin: CGSize = .zero

    /// Смещение текущего перетаскивания — живёт только пока палец на экране.
    @State private var drag: CGSize = .zero

    /// Двинули больше 5 pt — значит тащат, а не тапают (тут порог в квадрате).
    private static let tapLimit: CGFloat = 25

    init(minX: CGFloat, maxX: CGFloat, minY: CGFloat, maxY: CGFloat,
         isOpen: Bool, action: @escaping () -> Void) {
        self.minX = minX
        self.maxX = maxX
        self.minY = minY
        self.maxY = maxY
        self.isOpen = isOpen
        self.action = action
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.52, green: 0.52, blue: 0.56),
                                              Color(red: 0.29, green: 0.29, blue: 0.33)],
                                     startPoint: .top, endPoint: .bottom))

            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .stroke(Color.white.opacity(0.22), lineWidth: 1)

            Image(systemName: isOpen ? "xmark" : "slider.horizontal.3")
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.white)
        }
        .frame(width: MenuTrigger.side, height: MenuTrigger.side)
        .contentShape(Rectangle())          // вся площадь ловит касания
        .offset(x: position.width, y: position.height)
        .gesture(dragGesture)
    }

    private var position: CGSize {
        clamp(CGSize(width: origin.width + drag.width,
                     height: origin.height + drag.height))
    }

    private func clamp(_ s: CGSize) -> CGSize {
        CGSize(width: min(max(s.width, minX), max(minX, maxX)),
               height: min(max(s.height, minY), max(minY, maxY)))
    }

    private func moved(_ t: CGSize) -> Bool {
        t.width * t.width + t.height * t.height > MenuTrigger.tapLimit
    }

    /// Ручной драг на `@State` (а не на `@GestureState` и не через
    /// `withAnimation`): состояние меняется только внутри самой кнопки,
    /// и когда палец отпускают — сбрасывается ровно один раз. Именно
    /// сочетание `@GestureState` + анимации в родителе подвешивало UI.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if moved(value.translation) { drag = value.translation }
            }
            .onEnded { value in
                if moved(value.translation) {
                    origin = clamp(CGSize(width: origin.width + value.translation.width,
                                          height: origin.height + value.translation.height))
                } else {
                    action()
                }
                drag = .zero
            }
    }
}
