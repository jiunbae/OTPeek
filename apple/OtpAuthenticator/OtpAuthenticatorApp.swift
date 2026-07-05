import SwiftUI

@main
struct OtpAuthenticatorApp: App {
    @StateObject private var appState = OtpStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        #endif

        #if os(macOS)
        Settings {
            SettingsView()
                .environmentObject(appState)
        }

        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
        } label: {
            Image(systemName: "lock.shield.fill")
        }
        .menuBarExtraStyle(.window)
        #endif
    }
}

/// 볼트 준비 여부에 따라 온보딩 또는 메인 UI 를 보여준다.
struct RootView: View {
    @EnvironmentObject var appState: OtpStore

    var body: some View {
        if appState.isReady {
            ContentView()
        } else {
            OnboardingView()
        }
    }
}
