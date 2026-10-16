import Foundation
import Darwin
#if canImport(UIKit)
import UIKit
#endif

final class HUDLauncher {
    static let shared = HUDLauncher()
    
    private init() {}
    
    func launchHUD() {
        // Simplified - skip spawning for now to avoid compilation issues
        // The HUD window is managed separately
    }
    
    func killAllHUD() {
        // Simplified
    }
    
    func hideHUD() {
        HUDWindowManager.shared.hideHUD()
    }
}
