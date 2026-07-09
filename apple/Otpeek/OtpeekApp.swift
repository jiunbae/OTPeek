import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
struct OtpeekApp: App {
    @StateObject private var appState = OtpStore()
    @StateObject private var incoming = IncomingVaultFile.shared
    @StateObject private var appLock = AppLock()
    @StateObject private var store = StoreManager()

    #if os(macOS)
    @AppStorage("showInMenuBar") private var showInMenuBar = true
    @AppStorage("hideDockIconWhenNoWindows") private var hideDockIconWhenNoWindows = true

    // macOS 에서 SwiftUI App 의 .onOpenURL 은 파일(문서) 오픈에 신뢰성이 떨어진다.
    // Finder 더블클릭 / AirDrop 수신은 AppDelegate 의 application(_:open:) 로 받는 것이 확실하다.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// A template menu-bar icon sized to fill the bar. Built from the SF Symbol
    /// at an explicit point size because MenuBarExtra ignores SwiftUI font sizing.
    static var menuBarIcon: NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 19, weight: .semibold)
        let image = NSImage(systemSymbolName: "lock.shield.fill",
                            accessibilityDescription: "OTPeek")?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        return image ?? NSImage()
    }
    #endif

    var body: some Scene {
        #if os(macOS)
        WindowGroup("OTPeek", id: DockIconController.mainWindowGroupID) {
            RootView()
                .environmentObject(appState)
                .environmentObject(incoming)
                .environmentObject(appLock)
                .environmentObject(store)
                .background(DockManagedWindow(identifier: DockIconController.mainWindowIdentifier))
                // Feeds the custom NSStatusItem the app's live objects + window-open
                // action (SwiftUI creates this window at launch, so this runs early).
                .background(MenuBarBridge(appState: appState, appLock: appLock))
                .dockActivationPreferences(
                    showInMenuBar: showInMenuBar,
                    hideDockIconWhenNoWindows: hideDockIconWhenNoWindows
                )
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(appLock)
                .environmentObject(store)
                .background(DockManagedWindow(identifier: DockIconController.settingsWindowIdentifier))
                .dockActivationPreferences(
                    showInMenuBar: showInMenuBar,
                    hideDockIconWhenNoWindows: hideDockIconWhenNoWindows
                )
        }

        // The menu bar entry is a hand-rolled NSStatusItem (see StatusItemController),
        // not a SwiftUI MenuBarExtra: MenuBarExtra's .window style has no way to add a
        // right-click menu (Open / Settings / Quit). The status item is created and
        // shown/hidden by MenuBarBridge in response to the `showInMenuBar` setting.
        #else
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .environmentObject(incoming)
                .environmentObject(appLock)
                .environmentObject(store)
                // iOS 는 열린 문서를 .onOpenURL 로 받는다(문서/URL 스킴 모두 신뢰성 있음).
                .onOpenURL { url in incoming.load(from: url) }
        }
        #endif
    }
}

#if os(macOS)
/// macOS 문서 오픈(더블클릭 / AirDrop 수신)을 받아 앱 UI 로 넘긴다.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DockIconController.shared.startFromDefaults()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        DockIconController.shared.showDockIconForWindow()
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        DockIconController.shared.showDockIconForWindow()
        // AppKit 은 이 콜백을 메인 스레드에서 호출한다.
        MainActor.assumeIsolated {
            for url in urls { IncomingVaultFile.shared.load(from: url) }
        }
    }
}

final class DockIconController {
    static let shared = DockIconController()

    static let mainWindowGroupID = "main"
    static let mainWindowIdentifier = NSUserInterfaceItemIdentifier("otpeek.main-window")
    static let settingsWindowIdentifier = NSUserInterfaceItemIdentifier("otpeek.settings-window")

    private var showInMenuBar = true
    private var hideDockIconWhenNoWindows = true
    private var observers: [NSObjectProtocol] = []
    /// While this is in the future, the app is pinned to `.regular` regardless of
    /// window state. Set when we explicitly open a window from the menu bar so the
    /// popover closing (which fires a policy update) can't demote us to `.accessory`
    /// before the new window has a chance to become key.
    private var suppressAccessoryUntil = Date.distantPast

    private init() {}

    func startFromDefaults() {
        startObservingWindows()
        configure(
            showInMenuBar: Self.defaultedBool(forKey: "showInMenuBar", defaultValue: true),
            hideDockIconWhenNoWindows: Self.defaultedBool(forKey: "hideDockIconWhenNoWindows", defaultValue: true)
        )
    }

    func configure(showInMenuBar: Bool, hideDockIconWhenNoWindows: Bool) {
        self.showInMenuBar = showInMenuBar
        self.hideDockIconWhenNoWindows = hideDockIconWhenNoWindows
        schedulePolicyUpdate()
    }

    func showDockIconForWindow() {
        // Opening a window from the menu bar races with the popover closing (which
        // fires a policy update). Pin to .regular now and refuse to demote back to
        // .accessory for a short grace period, so the newly opened Settings/main
        // window keeps key focus and menu-bar ownership.
        suppressAccessoryUntil = Date().addingTimeInterval(1.0)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Re-evaluate once the grace period ends, in case the window was closed
        // again within it (otherwise the Dock icon could stay stuck).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
            self?.updateActivationPolicy()
        }
    }

    @discardableResult
    func focusMainWindow() -> Bool {
        guard let window = NSApp.windows.first(where: { $0.identifier == Self.mainWindowIdentifier }) else {
            return false
        }
        showDockIconForWindow()
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        return true
    }

    func focusMainWindowSoon() {
        DispatchQueue.main.async { self.focusMainWindow() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.focusMainWindow() }
    }

    func schedulePolicyUpdate(settling: Bool = false) {
        DispatchQueue.main.async { self.updateActivationPolicy() }
        guard settling else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { self.updateActivationPolicy() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.updateActivationPolicy() }
    }

    private func startObservingWindows() {
        guard observers.isEmpty else { return }

        let center = NotificationCenter.default
        let immediateUpdateNames: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didResignMainNotification
        ]
        let settlingUpdateNames: [Notification.Name] = [
            NSWindow.didMiniaturizeNotification,
            NSWindow.willCloseNotification
        ]

        observers = immediateUpdateNames.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.schedulePolicyUpdate()
            }
        }
        observers += settlingUpdateNames.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.schedulePolicyUpdate(settling: true)
            }
        }
    }

    private func updateActivationPolicy() {
        guard hideDockIconWhenNoWindows, showInMenuBar else {
            NSApp.setActivationPolicy(.regular)
            return
        }
        if Date() < suppressAccessoryUntil {
            NSApp.setActivationPolicy(.regular)
            return
        }

        NSApp.setActivationPolicy(hasVisibleStandardWindow ? .regular : .accessory)
    }

    /// Whether a real, user-facing app window (main or Settings) is on screen.
    /// We key off `.titled` — not our custom identifier — because the identifier is
    /// attached asynchronously by `DockManagedWindow`, and the policy update can run
    /// before it lands (the race that made the Settings window open-then-close). The
    /// borderless MenuBarExtra popover has no `.titled` style, so it is excluded; the
    /// identifier check stays as a fast path for windows we've already tagged.
    private var hasVisibleStandardWindow: Bool {
        NSApp.windows.contains { window in
            guard window.isVisible, !window.isMiniaturized, window.windowNumber > 0 else {
                return false
            }
            if window.identifier == Self.mainWindowIdentifier ||
                window.identifier == Self.settingsWindowIdentifier {
                return true
            }
            return window.styleMask.contains(.titled) && !(window is NSPanel)
        }
    }

    private static func defaultedBool(forKey key: String, defaultValue: Bool) -> Bool {
        guard UserDefaults.standard.object(forKey: key) != nil else { return defaultValue }
        return UserDefaults.standard.bool(forKey: key)
    }
}

/// Bridges SwiftUI window actions to AppKit call sites (the status item's popover
/// and right-click menu) that live outside the scene graph and can't use
/// `@Environment(\.openWindow)`. Captured once from the live main-window scene.
@MainActor
final class WindowActions {
    static let shared = WindowActions()
    /// Opens (or reuses) the main window. Set from `MenuBarBridge`.
    var openMain: (() -> Void)?
    private init() {}
}

/// Owns the menu bar entry: a custom `NSStatusItem` whose left-click toggles the
/// account popover and whose right-click shows an Open / Settings / Quit menu —
/// the right-click menu that SwiftUI's `MenuBarExtra` cannot provide.
@MainActor
final class StatusItemController {
    static let shared = StatusItemController()

    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private weak var appState: OtpStore?
    private weak var appLock: AppLock?

    private init() {
        popover.behavior = .transient
        popover.animates = true
    }

    /// Supplies the app's live objects so the popover shows the same accounts as
    /// the rest of the app. Safe to call repeatedly.
    func configure(appState: OtpStore, appLock: AppLock) {
        self.appState = appState
        self.appLock = appLock
    }

    func setVisible(_ visible: Bool) {
        visible ? install() : remove()
    }

    private func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = OtpeekApp.menuBarIcon
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(handleClick(_:))
            // Receive both mouse buttons so we can branch left vs. right click.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    private func remove() {
        if popover.isShown { popover.performClose(nil) }
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isRight = event?.type == .rightMouseUp
            || (event?.modifierFlags.contains(.control) ?? false)
        isRight ? showMenu(from: sender) : togglePopover(sender)
    }

    private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let appState, let appLock else { return }
        let root = MenuBarView()
            .environmentObject(appState)
            .environmentObject(appLock)
        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        // Make the popover key so the search field can auto-focus, without
        // promoting the whole app to .regular (which would flash the Dock icon).
        DispatchQueue.main.async { [weak self] in
            self?.popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showMenu(from sender: NSStatusBarButton) {
        let menu = NSMenu()

        let open = NSMenuItem(title: "Open OTPeek",
                              action: #selector(openMain), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        let settings = NSMenuItem(title: "Settings…",
                                  action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Quit OTPeek",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))

        // Pop up anchored under the status button; using popUp (not statusItem.menu)
        // keeps left-click bound to the popover.
        let origin = NSPoint(x: 0, y: sender.bounds.height + 4)
        menu.popUp(positioning: nil, at: origin, in: sender)
    }

    @objc private func openMain() {
        DockIconController.shared.showDockIconForWindow()
        if !DockIconController.shared.focusMainWindow() {
            WindowActions.shared.openMain?()
            DockIconController.shared.focusMainWindowSoon()
        }
    }

    @objc private func openSettings() {
        DockIconController.shared.showDockIconForWindow()
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Lives in the main window scene: captures the app's objects and the SwiftUI
/// window-open action for the status item, and shows/hides the status item to
/// track the `showInMenuBar` setting (replacing MenuBarExtra's `isInserted:`).
private struct MenuBarBridge: View {
    let appState: OtpStore
    let appLock: AppLock
    @Environment(\.openWindow) private var openWindow
    @AppStorage("showInMenuBar") private var showInMenuBar = true

    var body: some View {
        Color.clear
            .onAppear {
                WindowActions.shared.openMain = {
                    openWindow(id: DockIconController.mainWindowGroupID)
                }
                StatusItemController.shared.configure(appState: appState, appLock: appLock)
                StatusItemController.shared.setVisible(showInMenuBar)
            }
            .onChange(of: showInMenuBar) { _, visible in
                StatusItemController.shared.setVisible(visible)
            }
    }
}

private struct DockManagedWindow: NSViewRepresentable {
    let identifier: NSUserInterfaceItemIdentifier

    func makeNSView(context: Context) -> DockManagedNSView {
        let view = DockManagedNSView()
        view.managedWindowIdentifier = identifier
        return view
    }

    func updateNSView(_ nsView: DockManagedNSView, context: Context) {
        nsView.managedWindowIdentifier = identifier
        nsView.attachToWindow()
    }
}

private final class DockManagedNSView: NSView {
    var managedWindowIdentifier: NSUserInterfaceItemIdentifier?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachToWindow()
    }

    func attachToWindow() {
        guard let window, let managedWindowIdentifier else { return }
        window.identifier = managedWindowIdentifier
        DockIconController.shared.schedulePolicyUpdate(settling: true)
    }
}

private struct DockActivationPreferences: ViewModifier {
    let showInMenuBar: Bool
    let hideDockIconWhenNoWindows: Bool

    func body(content: Content) -> some View {
        content
            .onAppear { apply() }
            .onChange(of: showInMenuBar) { _, _ in apply() }
            .onChange(of: hideDockIconWhenNoWindows) { _, _ in apply() }
    }

    private func apply() {
        DockIconController.shared.configure(
            showInMenuBar: showInMenuBar,
            hideDockIconWhenNoWindows: hideDockIconWhenNoWindows
        )
    }
}

private extension View {
    func dockActivationPreferences(
        showInMenuBar: Bool,
        hideDockIconWhenNoWindows: Bool
    ) -> some View {
        modifier(DockActivationPreferences(
            showInMenuBar: showInMenuBar,
            hideDockIconWhenNoWindows: hideDockIconWhenNoWindows
        ))
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

    /// `otpeek://` 딥링크로 넘어온, 아직 추가되지 않은 otpauth URI.
    @Published var pendingAddURI: String?

    private init() {}

    func load(from url: URL) {
        // otpeek:// 앱 딥링크는 파일이 아니라 URI 명령이므로 별도로 라우팅한다.
        if url.scheme?.lowercased() == "otpeek" {
            handleDeepLink(url)
            return
        }
        // iOS 등 샌드박스에서 넘어온 URL 은 읽기 전에 보안 스코프 접근을 시작해야 한다.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let data = try? Data(contentsOf: url) {
            pendingData = data
        }
    }

    /// `otpeek://` 딥링크를 해석해 추가할 otpauth URI 를 대기열에 올린다.
    /// - `otpeek://totp/…` / `otpeek://hotp/…` → 스킴만 otpauth 로 바꿔 그대로 파싱
    /// - `otpeek://add?uri=<url-encoded otpauth>` → 감싼 otpauth URI 추출
    /// - `otpeek://` (그 외) → 동작 없음(앱만 전면으로)
    private func handleDeepLink(_ url: URL) {
        let host = url.host?.lowercased()
        if host == "totp" || host == "hotp" {
            let tail = url.absoluteString.dropFirst("otpeek://".count)
            pendingAddURI = "otpauth://" + tail
            return
        }
        if host == "add",
           let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let uri = comps.queryItems?.first(where: { $0.name == "uri" })?.value,
           !uri.isEmpty {
            pendingAddURI = uri
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
        // otpeek:// 딥링크로 들어온 계정 추가를 적절한 시점(볼트 열림 + 잠금 해제)에 적용.
        .onChange(of: incoming.pendingAddURI) { _, _ in applyPendingAdd() }
        .onChange(of: appState.isReady) { _, _ in applyPendingAdd() }
        .onChange(of: appLock.isLocked) { _, _ in applyPendingAdd() }
        .task { applyPendingAdd() }
    }

    /// otpeek:// 딥링크로 대기 중인 otpauth URI 를, 볼트가 열리고 잠금이 풀린 뒤 추가한다.
    private func applyPendingAdd() {
        guard appState.isReady,
              !(appLock.isEnabled && appLock.isLocked),
              let uri = incoming.pendingAddURI else { return }
        incoming.pendingAddURI = nil
        appState.addFromUri(uri)
    }

    private var importSheetBinding: Binding<Bool> {
        Binding(
            get: { appState.isReady && incoming.pendingData != nil },
            set: { presented in if !presented { incoming.pendingData = nil } }
        )
    }
}
