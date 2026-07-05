import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
struct OtpAuthenticatorApp: App {
    @StateObject private var appState = OtpStore()
    @StateObject private var incoming = IncomingVaultFile.shared
    @StateObject private var appLock = AppLock()

    #if os(macOS)
    // macOS 에서 SwiftUI App 의 .onOpenURL 은 파일(문서) 오픈에 신뢰성이 떨어진다.
    // Finder 더블클릭 / AirDrop 수신은 AppDelegate 의 application(_:open:) 로 받는 것이 확실하다.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// A template menu-bar icon sized to fill the bar. Built from the SF Symbol
    /// at an explicit point size because MenuBarExtra ignores SwiftUI font sizing.
    static var menuBarIcon: NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 19, weight: .semibold)
        let image = NSImage(systemSymbolName: "lock.shield.fill",
                            accessibilityDescription: "OTP Authenticator")?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        return image ?? NSImage()
    }
    #endif

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .environmentObject(incoming)
                .environmentObject(appLock)
                #if os(iOS)
                // iOS 는 열린 문서를 .onOpenURL 로 받는다(문서/URL 스킴 모두 신뢰성 있음).
                .onOpenURL { url in incoming.load(from: url) }
                #endif
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        #endif

        #if os(macOS)
        Settings {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(appLock)
        }

        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
                .environmentObject(appLock)
        } label: {
            // SwiftUI ignores .font() on a MenuBarExtra label, so build an
            // explicitly-sized template NSImage to fill the menu bar height.
            Image(nsImage: Self.menuBarIcon)
        }
        .menuBarExtraStyle(.window)
        #endif
    }
}

#if os(macOS)
/// macOS 문서 오픈(더블클릭 / AirDrop 수신)을 받아 앱 UI 로 넘긴다.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        // AppKit 은 이 콜백을 메인 스레드에서 호출한다.
        MainActor.assumeIsolated {
            for url in urls { IncomingVaultFile.shared.load(from: url) }
        }
    }
}
#endif

/// 외부에서 열린 `.otpvault` 파일을 앱 UI(가져오기 시트 / 온보딩 복원)로 중계한다.
/// URL 을 즉시 읽어 `Data` 로 들고 있으므로 보안 스코프 접근 수명을 신경 쓸 필요가 없다.
@MainActor
final class IncomingVaultFile: ObservableObject {
    static let shared = IncomingVaultFile()

    /// 아직 처리되지 않은, 방금 열린 볼트 파일의 내용.
    @Published var pendingData: Data?

    private init() {}

    func load(from url: URL) {
        // iOS 등 샌드박스에서 넘어온 URL 은 읽기 전에 보안 스코프 접근을 시작해야 한다.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let data = try? Data(contentsOf: url) {
            pendingData = data
        }
    }
}

/// 볼트 준비 여부에 따라 온보딩 또는 메인 UI 를 보여준다.
struct RootView: View {
    @EnvironmentObject var appState: OtpStore
    @EnvironmentObject var incoming: IncomingVaultFile
    @EnvironmentObject var appLock: AppLock
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Group {
                if appState.isReady {
                    ContentView()
                } else {
                    OnboardingView()
                }
            }
            // 볼트가 열려 있을 때만 가져오기 시트를 띄운다.
            // 볼트 미설정(fresh install) 상태에서는 OnboardingView 가 파일을 복원 blob 으로 소비한다.
            .sheet(isPresented: importSheetBinding) {
                if let data = incoming.pendingData {
                    ImportVaultView(data: data)
                        .environmentObject(appState)
                        .environmentObject(incoming)
                }
            }

            // Biometric lock gate — fully covers the UI (codes never shown while locked).
            if appLock.isEnabled && appLock.isLocked {
                LockView()
                    .environmentObject(appLock)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: appLock.isLocked)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:                     appLock.didBecomeActive()
            case .inactive, .background:      appLock.didResignActive()
            @unknown default:                 break
            }
        }
    }

    private var importSheetBinding: Binding<Bool> {
        Binding(
            get: { appState.isReady && incoming.pendingData != nil },
            set: { presented in if !presented { incoming.pendingData = nil } }
        )
    }
}
