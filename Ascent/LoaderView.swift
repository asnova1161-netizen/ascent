import SwiftUI
import UIKit

struct LoaderView: View {
    @StateObject private var state = LoaderState()

    var body: some View {
        // Один-единственный GeometryReader на весь экран. Всё остальное
        // расставляется СТАТИЧНЫМИ offset'ами: когда таскаешь меню или
        // квадратик, ничего в раскладке не меняется — перерисовывается
        // только то, что тащишь. Раньше тут были GeometryReader + .position,
        // и каждый кадр пересчитывался весь экран, от этого всё и залипало.
        GeometryReader { geo in
            let size = geo.size
            let top = max(geo.safeAreaInsets.top, 44)
            let bottom = max(geo.safeAreaInsets.bottom, 16)

            ZStack(alignment: .topLeading) {
                // фон и дождь — статичные типы, их SwiftUI не перерисовывает
                BackdropView()

                // дождь — тоже статичный UIViewRepresentable: SwiftUI его не
                // перерисовывает, капли крутит Core Animation. Внутри вью
                // неинтерактивно, поэтому касания уходят в интерфейс лоадера.
                RainView()

                LoaderContent(state: state, topInset: top, bottomInset: bottom)

                // Квадратик и меню здесь БОЛЬШЕ НЕ РИСУЕМ — ни запасной, ни
                // свой. Раньше приложение показывало запасной квадрат, пока HUD
                // не подтвердит свой: получалось два квадрата, а тап по
                // запасному открывал СТАРОЕ меню приложения вместо нового меню
                // HUD. Потом HUD поднимался, старое меню пропадало и появлялось
                // новое — именно эту путаницу и убираем.
                //
                // Квадрат и панель рисует ТОЛЬКО HUD-процесс. Приложение лишь
                // включает его и следит, что он жив (кнопка Start/Exit).

                // Версия iOS — поверх всего, но не мешает нажатиям.
                Text("iOS \(UIDevice.current.systemVersion)")
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundColor(Color.white.opacity(0.35))
                    .shadow(color: Color.black.opacity(0.5), radius: 3, x: 0, y: 1)
                    .padding(.leading, 16)
                    .padding(.top, top + 6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .allowsHitTesting(false)
                    .zIndex(10)

                // Отладочное окно: открывается ТОЛЬКО длинным тапом по «ascent».
                // Само по себе на экране ничего не пишет.
                if state.debugVisible {
                    DebugOverlay(state: state, topInset: top, bottomInset: bottom)
                        .zIndex(20)
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Лоадер

private struct LoaderContent: View {
    @ObservedObject var state: LoaderState
    let topInset: CGFloat
    let bottomInset: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            Text("ascent")
                // Шрифт — моноширинный (как у заголовка в меню-эталоне,
                // там своя «техничная» гарнитура), и чуть ниже прежнего.
                .font(.system(size: 44, weight: .heavy, design: .monospaced))
                // Цвет надписи — тот же серо-тёмный градиент, что и у кнопки
                // Start (по заказу). foregroundStyle — только iOS 15+, а цель
                // проекта iOS 14, поэтому градиент кладём ФОНОМ и обрезаем его
                // маской того же текста: получается ровно тот же вид.
                .foregroundColor(.clear)
                .background(
                    LinearGradient(colors: [Theme.grayTop, Theme.grayBottom],
                                   startPoint: .top, endPoint: .bottom)
                        .mask(
                            Text("ascent")
                                .font(.system(size: 44, weight: .heavy, design: .monospaced))
                                .foregroundColor(.black)
                        )
                )
                .shadow(color: Color.black.opacity(0.5), radius: 14, x: 0, y: 4)
                .offset(y: -8)
                // Отладочное окно: длинный тап по заголовку.
                .onLongPressGesture(minimumDuration: 0.6) {
                    state.toggleDebug()
                }

            startButton
                .padding(.top, 40)

            Spacer(minLength: 0)

            telegramLink
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 24)
        .padding(.top, topInset)
        .padding(.bottom, bottomInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var startButton: some View {
        Button(action: state.tapStart) {
            Text((state.showing || state.engaged) ? "Exit" : "Start")
                .font(.system(size: 15, weight: .heavy))
                .kerning(3)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 19)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(LinearGradient(colors: [Theme.grayTop, Theme.grayBottom],
                                             startPoint: .top, endPoint: .bottom))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Theme.grayLine, lineWidth: 1)
                )
        }
        .buttonStyle(StartButtonStyle())
        .shadow(color: Color.black.opacity(0.35), radius: 18, x: 0, y: 10)
        .offset(y: 40)          // кнопка Start/Exit чуть ниже центра
    }

    private var telegramLink: some View {
        Link(destination: URL(string: "https://t.me/ascentios")!) {
            HStack(spacing: 9) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 13, weight: .semibold))
                Text("t.me/ascentios")
                    .font(.system(size: 13, weight: .medium))
                    .kerning(0.4)
            }
            .foregroundColor(.white)
            .padding(.vertical, 11)
            .padding(.horizontal, 18)
            .background(
                ZStack {
                    Capsule().fill(LinearGradient(colors: [Theme.grayTop, Theme.grayBottom],
                                                  startPoint: .top, endPoint: .bottom))
                    Capsule().stroke(Theme.grayLine, lineWidth: 1)
                }
            )
        }
    }
}

// MARK: - Фон

/// Фон — статичная картинка с уже «впечённым» размытием (ассет `BackdropBlur`).
///
/// Раньше это была SwiftUI-вью с живым `.blur(radius: 9)`: размытие считалось
/// заново на каждом кадре и на iPhone 7 подвешивало интерфейс. Плюс попытка
/// размывать картинку кодом (CoreImage) прямо при запуске не давала
/// приложению открыться на этом устройстве. Теперь картинка размыта заранее
/// и лежит готовым ассетом, а `updateUIView` пустой — SwiftUI фон вообще не
/// трогает во время перетаскивания меню и квадрата.
private struct BackdropView: UIViewRepresentable {
    func makeUIView(context: Context) -> BackdropUIView { BackdropUIView() }
    func updateUIView(_ uiView: BackdropUIView, context: Context) { }
}

private final class BackdropUIView: UIView {
    private let imageView = UIImageView()
    private let flat = CALayer()
    private let dim = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .black
        clipsToBounds = true

        // imageView.contentMode = .scaleAspectFill, а не .scaleAspectFit:
        // картинка (1320x2868) выше экрана iPhone 7, и при «fit» она
        // ужималась по высоте, оставляя чёрные полосы слева и справа.
        // «Fill» растягивает фото на всю ширину — полос по бокам нет.
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.image = UIImage(named: "BackdropBlur")
        addSubview(imageView)

        flat.backgroundColor = UIColor.black.withAlphaComponent(0.10).cgColor
        layer.addSublayer(flat)

        dim.colors = [UIColor.black.withAlphaComponent(0.22).cgColor,
                      UIColor.clear.cgColor,
                      UIColor.black.withAlphaComponent(0.38).cgColor]
        dim.locations = [0.0, 0.5, 1.0]
        layer.addSublayer(dim)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
        flat.frame = bounds
        dim.frame = bounds
    }
}

// MARK: - Короткая диагностика оверлея (полоска убрана)

struct LoaderView_Previews: PreviewProvider {
    static var previews: some View {
        LoaderView().preferredColorScheme(.dark)
    }
}
