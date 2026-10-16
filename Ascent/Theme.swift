import SwiftUI

enum Theme {
    // Осенняя палитра
    static let gold     = Color(red: 0.965, green: 0.749, blue: 0.310)   // #f6bf4f
    static let goldSoft = Color(red: 0.988, green: 0.878, blue: 0.565)   // #fce090
    static let amber    = Color(red: 0.878, green: 0.522, blue: 0.157)   // #e08528
    static let rust     = Color(red: 0.760, green: 0.353, blue: 0.098)   // #c25a19
    static let deepRust = Color(red: 0.639, green: 0.235, blue: 0.078)   // #a33c14

    static let bg     = Color(red: 0.070, green: 0.047, blue: 0.027)   // #120c07
    static let text   = Color(red: 0.988, green: 0.953, blue: 0.882)   // #fcf3e1
    static let muted  = Color(red: 0.988, green: 0.953, blue: 0.882).opacity(0.55)
    static let line   = Color(red: 1.000, green: 0.851, blue: 0.600).opacity(0.18)
    static let onGold = Color(red: 0.176, green: 0.086, blue: 0.020)

    // Серый «как квадратик» (MenuTrigger) — для кнопок Start и t.me/ascentios
    static let grayTop    = Color(red: 0.520, green: 0.520, blue: 0.560)
    static let grayBottom = Color(red: 0.290, green: 0.290, blue: 0.330)
    static let grayLine   = Color.white.opacity(0.22)
}

struct StartButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeOut(duration: 0.12))
    }
}
