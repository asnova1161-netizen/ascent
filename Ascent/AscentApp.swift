import SwiftUI

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
                        // HUD is launched as separate process via main()
                    }
            } else {
                LoaderView()
                    .preferredColorScheme(.dark)
            }
        }
    }
}
