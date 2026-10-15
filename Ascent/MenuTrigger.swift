import SwiftUI

/// Серая плавающая кнопка мод-меню.
///
/// Её можно таскать по всему экрану (границы считает родитель), а обычный
/// тап по ней открывает и закрывает меню.
struct MenuTrigger: View {
    @Binding var offset: CGSize

    let minX: CGFloat
    let maxX: CGFloat
    let minY: CGFloat
    let maxY: CGFloat
    let isOpen: Bool
    let action: () -> Void

    @State private var start: CGSize = .zero
    @State private var moved = false

    static let side: CGFloat = 54

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
        .offset(x: offset.width, y: offset.height)
        .onAppear { start = offset }
        .gesture(drag)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let moved2 = value.translation.width * value.translation.width
                    + value.translation.height * value.translation.height
                if !moved && moved2 > 25 { moved = true }
                guard moved else { return }
                let raw = CGSize(width: start.width + value.translation.width,
                                 height: start.height + value.translation.height)
                offset = CGSize(width: min(max(raw.width, minX), max(minX, maxX)),
                                height: min(max(raw.height, minY), max(minY, maxY)))
            }
            .onEnded { _ in
                if moved { start = offset } else { action() }
                moved = false
            }
    }
}
