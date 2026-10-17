import SwiftUI
import UIKit

/// Отладочное окно запуска оверлея.
///
/// Открывается длинным тапом по заголовку «ascent» (или автоматически, если
/// оверлей не подтвердился за 3 секунды) и обновляется раз в 2 секунды.
struct DebugOverlay: View {
    @ObservedObject var state: LoaderState
    let topInset: CGFloat
    let bottomInset: CGFloat

    private var verdictLine: String {
        state.debugText.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? ""
    }

    private var detailsText: String {
        let parts = state.debugText.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        return parts.count > 1 ? String(parts[1]) : ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Debug")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundColor(.white)

                Spacer(minLength: 0)

                Button(action: copyToPasteboard) {
                    Text("Скопировать")
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 11)
                        .background(Capsule().fill(Color.white.opacity(0.16)))
                }

                Button(action: state.closeDebug) {
                    Text("Закрыть")
                        .font(.system(size: 11.5, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 11)
                        .background(Capsule().fill(Color.white.opacity(0.16)))
                }
            }

            // Короткий вывод — самое важное, его легко переписать руками.
            Text(verdictLine)
                .font(.system(size: 12.5, weight: .bold))
                .foregroundColor(Color(red: 1.0, green: 0.85, blue: 0.4))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))

            ScrollView {
                Text(detailsText)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(Color(white: 0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(Color.black.opacity(0.94))
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

    private func copyToPasteboard() {
        UIPasteboard.general.string = state.debugText
    }
}
