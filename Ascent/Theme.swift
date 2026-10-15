import SwiftUI

enum Theme {
    static let green  = Color(red: 0.180, green: 0.910, blue: 0.604)   // #2ee89a
    static let green2 = Color(red: 0.059, green: 0.682, blue: 0.404)   // #0fae67
    static let bg     = Color(red: 0.020, green: 0.027, blue: 0.024)   // #050706
    static let text   = Color(red: 0.918, green: 0.961, blue: 0.937)   // #eaf5ef
    static let muted  = Color(red: 0.918, green: 0.961, blue: 0.937).opacity(0.42)
    static let line   = Color.white.opacity(0.07)
    static let onGreen = Color(red: 0.016, green: 0.078, blue: 0.047)
}

struct StartButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeOut(duration: 0.12))
    }
}
