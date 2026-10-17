import SwiftUI
import UIKit

struct LoaderView: View {
    @StateObject private var state = LoaderState()

    private let panelHeight: CGFloat = 216

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
            let panelWidth = min(size.width - 44, 300)

            ZStack(alignment: .topLeading) {
                // фон и дождь — статичные типы, их SwiftUI не перерисовывает
                BackdropView()

                // дождь — тоже статичный UIViewRepresentable: SwiftUI его не
                // перерисовывает, капли крутит Core Animation. Внутри вью
                // неинтерактивно, поэтому касания уходят к квадрату и меню.
                RainView()

                LoaderContent(state: state, topInset: top, bottomInset: bottom)

                // квадратик и меню живут, пока их не убрали кнопкой Exit:
                // unload останавливает лоадер, но НЕ прячет их.
                //
                // Когда поднят HUD-процесс, квадрат и панель рисует ОН (поверх
                // всех приложений). Внутри app их тогда не дублируем — иначе
                // получалось бы два квадрата: один в приложении, другой поверх.
                // Пока HUD не подтверждён, показываем квадрат внутри app, чтобы
                // он не пропадал во время запуска.
                if state.engaged && !state.showing {
                    trigger(size: size, top: top, bottom: bottom)
                        .zIndex(3)

                    if state.menuOpen {
                        panel(size: size, top: top, bottom: bottom, width: panelWidth)
                            .zIndex(2)
                    }
                }

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

                // Отладочное окно: длинный тап по «ascent» или автооткрытие,
                // если оверлей не поднялся.
                if state.debugVisible {
                    DebugOverlay(state: state, topInset: top, bottomInset: bottom)
                        .zIndex(20)
                }

                // Диагностика висит внизу, пока оверлей включён — а также если
                // прошлый запуск не дошёл до конца (упал): тогда причину видно
                // сразу, без длинных тапов.
                // Тап по полоске раскрывает полное отладочное окно.
                if state.engaged || state.showing || state.lastRunCrashed {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        HUDDiagnosticsStrip(state: state)
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, bottom + 6)
                    .zIndex(15)
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .ignoresSafeArea()
    }

    // MARK: - Квадратик мод-меню

    private func trigger(size: CGSize, top: CGFloat, bottom: CGFloat) -> some View {
        let side = MenuTrigger.side
        let baseX = size.width - side - 14
        let baseY = top + 14
        let area = CGRect(x: 10,
                          y: top + 10,
                          width: max(size.width - 20, 0),
                          height: max(size.height - top - bottom - 20, 0))

        return MenuTrigger(minX: area.minX - baseX,
                           maxX: max(area.maxX - side - baseX, area.minX - baseX),
                           minY: area.minY - baseY,
                           maxY: max(area.maxY - side - baseY, area.minY - baseY),
                           isOpen: state.menuOpen,
                           action: state.toggleMenu,
                           initialOrigin: OverlayStore.origin(for: "trigger"),
                           onOriginChange: { OverlayStore.setOrigin($0, for: "trigger") })
            .offset(x: baseX, y: baseY)
    }

    // MARK: - Меню

    private func panel(size: CGSize, top: CGFloat, bottom: CGFloat, width: CGFloat) -> some View {
        let baseX = (size.width - width) / 2
        // не по центру, а в свободной полосе под кнопкой Start,
        // чтобы сразу не закрывать Exit
        let baseY = size.height * 0.74 - panelHeight / 2
        let area = CGRect(x: 10,
                          y: top + 10,
                          width: max(size.width - 20, 0),
                          height: max(size.height - top - bottom - 20, 0))

        return MenuPanel(tab: $state.tab,
                         isRunning: state.running,
                         width: width,
                         height: panelHeight,
                         minX: area.minX - baseX,
                         maxX: max(area.maxX - width - baseX, area.minX - baseX),
                         minY: area.minY - baseY,
                         maxY: max(area.maxY - panelHeight - baseY, area.minY - baseY),
                         onClose: state.closeMenu,
                         onUnload: state.unload,
                         telegramURL: URL(string: "https://t.me/ascentios")!,
                         initialOrigin: OverlayStore.origin(for: "panel"),
                         onOriginChange: { OverlayStore.setOrigin($0, for: "panel") })
            .offset(x: baseX, y: baseY)
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
                .font(.system(size: 46, weight: .heavy, design: .rounded))
                .foregroundColor(.white)
                .shadow(color: Color.black.opacity(0.5), radius: 14, x: 0, y: 4)
                .offset(y: -26)
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
            Text(state.showing ? "Exit" : "Start")
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

// MARK: - Короткая диагностика оверлея

/// Полоска внизу экрана: «ПРИЧИНА: …» и последние шаги HUD-процесса.
///
/// Висит всё время, пока оверлей включён (от Start до Exit), чтобы причину не
/// приходилось искать вслепую: длинное отладочное окно открывается по нажатию.
private struct HUDDiagnosticsStrip: View {
    @ObservedObject var state: LoaderState

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(state.diagnosticsVerdict)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundColor(.yellow)
                .fixedSize(horizontal: false, vertical: true)

            if !state.diagnosticsSteps.isEmpty {
                Text(state.diagnosticsSteps)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.white.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(6)
            }

            Text("нажми, чтобы раскрыть подробности")
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Theme.grayLine, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { state.openDebug() }
    }
}

struct LoaderView_Previews: PreviewProvider {
    static var previews: some View {
        LoaderView().preferredColorScheme(.dark)
    }
}
