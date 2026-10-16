import UIKit
import SwiftUI

/// Entry point delegate for the normal (non-HUD) launch.
///
/// The application entry point lives in `HUDApp.mm` (`main`), which either
/// starts the HUD plugin process (`-hud`) or calls `UIApplicationMain` with
/// this delegate. The name is pinned with `@objc(AppDelegate)` so the ObjC
/// side can find it via `NSClassFromString(@"AppDelegate")`.
@objc(AppDelegate)
public class AppDelegate: UIResponder, UIApplicationDelegate {
    public var window: UIWindow?

    public func application(_ application: UIApplication,
                            didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        let host = UIHostingController(rootView: LoaderView().preferredColorScheme(.dark))
        host.view.backgroundColor = .black
        window.rootViewController = host
        window.overrideUserInterfaceStyle = .dark
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}
