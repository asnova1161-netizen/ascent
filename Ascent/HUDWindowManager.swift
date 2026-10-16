import Foundation
import SwiftUI
import UIKit

final class HUDWindowManager: NSObject {
    static let shared = HUDWindowManager()
    
    private var hudWindow: UIWindow?
    private var menuOpen = false
    
    override private init() {}
    
    func showHUD() {
        DispatchQueue.main.async {
            self.createHUDWindow()
        }
    }
    
    func hideHUD() {
        DispatchQueue.main.async {
            self.hudWindow?.isHidden = true
            self.hudWindow?.rootViewController = nil
            self.hudWindow = nil
        }
    }
    
    private func createHUDWindow() {
        let windowLevel: UIWindow.Level = {
            if #available(iOS 15.0, *) {
                return .statusBar - 1
            } else {
                return UIWindow.Level(rawValue: UIWindow.Level.statusBar.rawValue - 1)
            }
        }()
        
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.windowLevel = windowLevel
        window.backgroundColor = .clear
        window.isHidden = false
        window.rootViewController = HUDViewController()
        
        hudWindow = window
    }
}

final class HUDViewController: UIViewController {
    private var hostingController: UIHostingController<HUDContainerView>?
    private var menuOpen = false
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        
        let container = HUDContainerView(menuOpen: Binding(
            get: { self.menuOpen },
            set: { self.menuOpen = $0 }
        ))
        
        hostingController = UIHostingController(rootView: container)
        hostingController?.view.backgroundColor = .clear
        
        if let hostView = hostingController?.view {
            hostView.translatesAutoresizingMaskIntoConstraints = false
            addChild(hostingController!)
            view.addSubview(hostView)
            
            NSLayoutConstraint.activate([
                hostView.topAnchor.constraint(equalTo: view.topAnchor),
                hostView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                hostView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                hostView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
            hostingController?.didMove(toParent: self)
        }
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Pass touches through when not on trigger/panel
    }
    
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        // Don't consume touches by default - pass through
        // This allows touches to pass through to apps behind
    }
    
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        // Check if point is inside trigger or panel
        // Return true only if inside interactive elements
        let triggerSide: CGFloat = 54
        let triggerX = UIScreen.main.bounds.width - triggerSide - 14
        let triggerY = max(UIScreen.main.safeAreaInsets.top, 44) + 14
        let triggerRect = CGRect(x: triggerX, y: triggerY, width: triggerSide, height: triggerSide)
        
        if triggerRect.contains(point) {
            return true
        }
        
        if menuOpen {
            let panelWidth = min(UIScreen.main.bounds.width - 44, 300)
            let panelHeight: CGFloat = 216
            let baseX = (UIScreen.main.bounds.width - panelWidth) / 2
            let baseY = UIScreen.main.bounds.height * 0.74 - panelHeight / 2
            let panelRect = CGRect(x: baseX, y: baseY, width: panelWidth, height: panelHeight)
            if panelRect.contains(point) {
                return true
            }
        }
        
        return false
    }
}

struct HUDContainerView: View {
    @Binding var menuOpen: Bool
    private let panelHeight: CGFloat = 216
    
    var body: some View {
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
            onUnload: { terminateHUD() },
            telegramURL: URL(string: "https://t.me/ascentios")!
        )
        .offset(x: baseX, y: baseY)
    }
    
    private func terminateHUD() {
        HUDWindowManager.shared.hideHUD()
        exit(0)
    }
}
