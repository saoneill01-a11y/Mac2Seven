import AppKit
import SwiftUI

/// Debug builds only: `--demo` stages the menu for marketing screenshots — a generic user picture,
/// only Apple's built-in apps, and a colorful backdrop behind the glass. Always off in Release builds.
enum DemoMode {
    static var isOn: Bool {
        #if DEBUG
        return CommandLine.arguments.contains("--demo")
        #else
        return false
        #endif
    }
}

#if DEBUG
/// Full-screen backdrop drawn just below the menu, so the glass has something pretty to blur.
struct DemoBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.09, green: 0.17, blue: 0.42),
                         Color(red: 0.30, green: 0.16, blue: 0.52),
                         Color(red: 0.04, green: 0.42, blue: 0.55)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle()
                .fill(Color(red: 0.30, green: 0.82, blue: 0.92).opacity(0.55))
                .frame(width: 760, height: 760)
                .blur(radius: 130)
                .offset(x: 330, y: -160)
            Circle()
                .fill(Color(red: 0.92, green: 0.42, blue: 0.72).opacity(0.40))
                .frame(width: 640, height: 640)
                .blur(radius: 140)
                .offset(x: -360, y: 230)
            Circle()
                .fill(Color(red: 1.0, green: 0.78, blue: 0.45).opacity(0.25))
                .frame(width: 420, height: 420)
                .blur(radius: 120)
                .offset(x: -120, y: -300)
        }
        .ignoresSafeArea()
    }
}

/// Stand-in user picture so screenshots don't show the real account's photo.
struct DemoAvatar: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.98, green: 0.62, blue: 0.35), Color(red: 0.90, green: 0.33, blue: 0.45)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Text("AM")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
    }
}
#endif
