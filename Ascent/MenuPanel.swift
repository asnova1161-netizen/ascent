import SwiftUI

/// Плавающее меню мод-меню.
///
/// Панель непрозрачная (серый), текст белый. Её можно таскать за шапку,
/// но за края экрана она не уходит: границы (minX…maxX, minY…maxY)
/// считает родитель и передаёт сюда.
struct MenuPanel: View {
    @Binding var tab: Int
    @Binding var offset: CGSize

    let width: CGFloat
    let height: CGFloat
    let minX: CGFloat
    let maxX: CGFloat
    let minY: CGFloat
    let maxY: CGFloat

    let onClose: () -> Void
    let onUnload: () -> Void
    let telegramURL: URL

    @State private var dragStart: CGSize = .zero

    private let headerHeight: CGFloat = 44
    private let tabBarHeight: CGFloat = 40

    // серый фон непрозрачный + белый текст
    private let fill  = Color(red: 0.145, green: 0.145, blue: 0.160)
    private let line  = Color.white.opacity(0.12)
    private let dim   = Color.white.opacity(0.55)
    private let gray  = Color(red: 0.36, green: 0.36, blue: 0.40)

    var body: some View {
        VStack(spacing: 0) {
            header
            tabBar
            content
        }
        .frame(width: width, height: height)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous).fill(fill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(line, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.55), radius: 26, x: 0, y: 16)
        .offset(x: offset.width, y: offset.height)
        .onAppear { dragStart = offset }
    }

    // MARK: - Шапка (за неё таскаем)

    private var header: some View {
        HStack(spacing: 10) {
            Text("ascent")
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .kerning(1.6)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .gesture(drag)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(Color.white.opacity(0.85))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.white.opacity(0.10)))
                    .contentShape(Circle())
            }
        }
        .padding(.horizontal, 14)
        .frame(height: headerHeight)
        .overlay(Rectangle().fill(line).frame(height: 1), alignment: .bottom)
    }

    // MARK: - Вкладки

    private var tabBar: some View {
        HStack(spacing: 0) {
            tabButton("main", 0)
            tabButton("misc", 1)
        }
        .frame(height: tabBarHeight)
        .overlay(Rectangle().fill(line).frame(height: 1), alignment: .bottom)
    }

    private func tabButton(_ title: String, _ index: Int) -> some View {
        Button(action: { withAnimation(.easeInOut(duration: 0.15)) { tab = index } }) {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .kerning(0.6)
                    .foregroundColor(tab == index ? .white : dim)
                Rectangle()
                    .fill(tab == index ? Color.white : Color.clear)
                    .frame(height: 2)
                    .padding(.top, 7)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
    }

    // MARK: - Содержимое вкладок

    private var content: some View {
        Group {
            if tab == 0 { mainTab } else { miscTab }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
    }

    private var mainTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("статус")
                    .font(.system(size: 13))
                    .foregroundColor(dim)
                Spacer(minLength: 0)
                Text("загрузчик активен")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
            }

            Link(destination: telegramURL) {
                HStack(spacing: 9) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Text("t.me/ascentios")
                        .font(.system(size: 13, weight: .medium))
                        .kerning(0.3)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Color.white.opacity(0.45))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.07))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(line, lineWidth: 1)
                )
            }
        }
    }

    private var miscTab: some View {
        VStack(spacing: 8) {
            Button(action: onUnload) {
                Text("unload")
                    .font(.system(size: 14, weight: .heavy))
                    .kerning(1.4)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(gray)
                    )
            }
            .buttonStyle(StartButtonStyle())

            Text("закроет загрузчик полностью")
                .font(.system(size: 11.5))
                .foregroundColor(Color.white.opacity(0.5))
        }
    }

    // MARK: - Перетаскивание

    private var drag: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let raw = CGSize(width: dragStart.width + value.translation.width,
                                 height: dragStart.height + value.translation.height)
                offset = CGSize(
                    width: min(max(raw.width, minX), max(minX, maxX)),
                    height: min(max(raw.height, minY), max(minY, maxY))
                )
            }
            .onEnded { _ in dragStart = offset }
    }
}
