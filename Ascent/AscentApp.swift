import SwiftUI

@main
struct AscentApp: App {
    var body: some Scene {
        WindowGroup {
            LoaderView()
                .preferredColorScheme(.dark)
        }
    }
}
