import SwiftUI

/// Отладочное окно запуска оверлея.
///
/// Открывается длинным тапом по заголовку «ascent» (или автоматически, если
/// оверлей не подтвердился за 3 секунды) и обновляется раз в секунду.
struct DebugOverlay: View {
    @ObservedObject var state: LoaderState
    let topInset: CGFloat
    let bottomInset: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Debug — запуск оверлея")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundColor(.white)

                Spacer(minLength: 0)

                Button(action: state.closeDebug) {
                    Text("Закрыть")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 14)
                        .background(Capsule().fill(Color.white.opacity(0.16)))
                }
            }

            ScrollView {
                Text(state.debugText)
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundColor(Color(white: 0.92))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(Color.black.opacity(0.92))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        )
        .padding(.horizontal, 10)
        .padding(.top, max(topInset, 20) + 4)
        .padding(.bottom, max(bottomInset, 20) + 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
