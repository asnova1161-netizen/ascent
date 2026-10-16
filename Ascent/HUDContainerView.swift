import SwiftUI
import UIKit

public struct HUDContainerView: View {
    @State private var menuOpen: Bool
    @State private var tab = 0
    private let panelHeight: CGFloat = 216

    public init(menuOpen: Bool = false) {
        self._menuOpen = State(initialValue: menuOpen)
    }

    public init(withMenuOpen menuOpen: Bool) {
        self._menuOpen = State(initialValue: menuOpen)
    }

    public var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let top = max(geo.safeAreaInsets.top, 44)
            let bottom = max(geo.safeAreaInsets.bottom, 16)
            let panelWidth = min(size.width - 44, 300)

            // ВАЖНО: здесь нет фона на весь экран. Пустые места оверлея
            // должны пропускать касания в приложение под ним — window-сервер
            // спрашивает у окна hit-test, и если под пальцем нет ни квадрата,
            // ни панели, окно касание не забирает. Интерактивны только сами
            // элементы (у них свой contentShape).
            ZStack(alignment: .topLeading) {
                trigger(size: size, top: top, bottom: bottom)
                    .zIndex(3)

                if menuOpen {
                    panel(size: size, top: top, bottom: bottom, width: panelWidth)
                        .zIndex(2)
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .ignoresSafeArea()
    }

    private func trigger(size: CGSize, top: CGFloat, bottom: CGFloat) -> some View {
        let side = MenuTrigger.side
        let baseX = size.width - side - 14
        let baseY = top + 14
        let area = CGRect(x: 10, y: top + 10, width: max(size.width - 20, 0), height: max(size.height - top - bottom - 20, 0))

        return MenuTrigger(
            minX: area.minX - baseX,
            maxX: max(area.maxX - side - baseX, area.minX - baseX),
            minY: area.minY - baseY,
            maxY: max(area.maxY - side - baseY, area.minY - baseY),
            isOpen: menuOpen,
            action: { menuOpen.toggle() },
            initialOrigin: OverlayStore.origin(for: "trigger"),
            onOriginChange: { OverlayStore.setOrigin($0, for: "trigger") }
        )
        .offset(x: baseX, y: baseY)
    }

    private func panel(size: CGSize, top: CGFloat, bottom: CGFloat, width: CGFloat) -> some View {
        let baseX = (size.width - width) / 2
        let baseY = size.height * 0.74 - panelHeight / 2
        let area = CGRect(x: 10, y: top + 10, width: max(size.width - 20, 0), height: max(size.height - top - bottom - 20, 0))

        return MenuPanel(
            tab: $tab,
            isRunning: true,
            width: width,
            height: panelHeight,
            minX: area.minX - baseX,
            maxX: max(area.maxX - width - baseX, area.minX - baseX),
            minY: area.minY - baseY,
            maxY: max(area.maxY - panelHeight - baseY, area.minY - baseY),
            onClose: { menuOpen = false },
            onUnload: {
                // Кнопка закрытия в панели полностью гасит оверлей: снимаем
                // PID-файл (иначе главный процесс считал бы оверлей живым) и
                // завершаем HUD-процесс.
                AscentRemovePIDFile()
                exit(0)
            },
            telegramURL: URL(string: "https://t.me/ascentios")!,
            initialOrigin: OverlayStore.origin(for: "panel"),
            onOriginChange: { OverlayStore.setOrigin($0, for: "panel") }
        )
        .offset(x: baseX, y: baseY)
    }
}

/// ObjC bridge: builds the SwiftUI hosting controller.
///
/// The class name is looked up from Objective-C (`HUDRootViewController`), so it
/// must stay reachable via the runtime name, not only through Swift.
@objc(HUDHostFactory)
public final class HUDHostFactory: NSObject {
    @objc public static func makeHostingController() -> UIViewController {
        return UIHostingController(rootView: HUDContainerView().preferredColorScheme(.dark))
    }
}
