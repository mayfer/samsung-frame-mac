import AppKit
import SwiftUI

@main
struct SamsungFrameRemoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 560, height: 420)
    }
}
