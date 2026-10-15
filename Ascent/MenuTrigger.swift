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

    @State private var offset: CGSize = .zero
    @GestureState private var slide: CGSize = .zero

    static let side: CGFloat = 54

    /// Двинули больше 5 pt — значит тащат, а не тапают (тут порог в квадрате).
    private static let tapLimit: CGFloat = 25

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
        .background(
            // тень без размытия — при перетаскивании она не грузит кадры
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .fill(Color.black.opacity(0.40))
                .offset(y: 5)
        )
        .offset(x: current.width, y: current.height)
        .gesture(drag)
    }

    private var current: CGSize {
        clamp(CGSize(width: offset.width + slide.width, height: offset.height + slide.height))
    }

    private func clamp(_ s: CGSize) -> CGSize {
        CGSize(width: min(max(s.width, minX), max(minX, maxX)),
               height: min(max(s.height, minY), max(minY, maxY)))
    }

    private func moved(_ t: CGSize) -> Bool {
        t.width * t.width + t.height * t.height > MenuTrigger.tapLimit
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($slide) { value, state, _ in
                state = moved(value.translation) ? value.translation : .zero
            }
            .onEnded { value in
                if moved(value.translation) {
                    offset = clamp(CGSize(width: offset.width + value.translation.width,
                                          height: offset.height + value.translation.height))
                } else {
                    action()
                }
            }
    }
}
