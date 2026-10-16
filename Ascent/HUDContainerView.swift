import SwiftUI

@objc public class HUDContainerViewState: NSObject {
    @objc var menuOpen: Bool = false
}

@objcMembers
public class HUDContainerViewWrapper: NSObject {
    @objc public func makeView() -> Any? {
        return HUDContainerView(menuOpen: false)
    }
}

public struct HUDContainerView: View {
    @State private var menuOpen: Bool
    private let panelHeight: CGFloat = 216
    
    public init(menuOpen: Bool = false) {
        self._menuOpen = State(initialValue: menuOpen)
    }
    
    @objc public init(withMenuOpen menuOpen: Bool) {
        self._menuOpen = State(initialValue: menuOpen)
    }
    
    public var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let top = max(geo.safeAreaInsets.top, 44)
            let bottom = max(geo.safeAreaInsets.bottom, 16)
            let panelWidth = min(size.width - 44, 300)
            
            ZStack(alignment: .topLeading) {
                Color.clear
                
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
            action: { menuOpen.toggle() }
        )
        .offset(x: baseX, y: baseY)
    }
    
    private func panel(size: CGSize, top: CGFloat, bottom: CGFloat, width: CGFloat) -> some View {
        let baseX = (size.width - width) / 2
        let baseY = size.height * 0.74 - panelHeight / 2
        let area = CGRect(x: 10, y: top + 10, width: max(size.width - 20, 0), height: max(size.height - top - bottom - 20, 0))
        
        return MenuPanel(
            tab: .constant(0),
            isRunning: true,
            width: width,
            height: panelHeight,
            minX: area.minX - baseX,
            maxX: max(area.maxX - width - baseX, area.minX - baseX),
            minY: area.minY - baseY,
            maxY: max(area.maxY - panelHeight - baseY, area.minY - baseY),
            onClose: { menuOpen = false },
            onUnload: { exit(0) },
            telegramURL: URL(string: "https://t.me/ascentios")!
        )
        .offset(x: baseX, y: baseY)
    }
}
