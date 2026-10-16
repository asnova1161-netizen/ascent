import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

@main
struct AscentApp: App {
    private var isHUDMode: Bool {
        CommandLine.arguments.contains("-hud")
    }
    
    var body: some Scene {
        WindowGroup {
            if isHUDMode {
                EmptyView()
                    .onAppear {
                        HUDWindowManager.shared.showHUD()
                    }
            } else {
                LoaderView()
                    .preferredColorScheme(.dark)
            }
        }
    }
}
