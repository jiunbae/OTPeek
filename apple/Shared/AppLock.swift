import Foundation
import SwiftUI
import LocalAuthentication

/// App-level biometric lock (Touch ID / Face ID, with device-password fallback)
/// plus auto-lock after a period in the background. This gates the UI; the vault
/// itself is still key-wrapped at rest by the OS keystore.
@MainActor
public final class AppLock: ObservableObject {

    public static let enabledKey = "biometricLockEnabled"
    public static let timeoutKey = "autoLockMinutes"   // 0 = immediately

    /// True while the UI should be hidden behind the lock screen.
    @Published public private(set) var isLocked: Bool
    /// A transient auth error to surface on the lock screen.
    @Published public var authError: String?

    private var backgroundedAt: Date?

    public var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    private var autoLockMinutes: Int {
        UserDefaults.standard.object(forKey: Self.timeoutKey) as? Int ?? 5
    }

    public init() {
        // Start locked when the feature is on, so a launch always requires auth.
        isLocked = UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    /// Whether the device can actually do biometric/owner auth right now.
    public static func biometryAvailable() -> Bool {
        var error: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    /// Prompt for biometric (or device password) authentication.
    public func authenticate() {
        guard isLocked else { return }
        let context = LAContext()
        context.localizedFallbackTitle = "Enter Password"
        var error: NSError?

        // Probe biometrics explicitly: `.deviceOwnerAuthentication` silently falls
        // back to the passcode when Face ID is unavailable, so surface WHY on the
        // lock screen (e.g. per-app Face ID permission denied, not enrolled, …).
        var bioError: NSError?
        let canBio = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &bioError)
        #if DEBUG
        print("[AppLock] biometry probe: canBio=\(canBio) type=\(context.biometryType.rawValue) " +
              "error=\((bioError as? LAError).map { "LAError \($0.code.rawValue) \($0.localizedDescription)" } ?? "none")")
        #endif
        if !canBio {
            let detail = (bioError as? LAError).map { "LAError \($0.code.rawValue): \($0.localizedDescription)" }
                ?? bioError?.localizedDescription
                ?? "unknown"
            authError = "Biometrics unavailable — \(detail) (biometryType=\(context.biometryType.rawValue))"
        }

        // If the device can't authenticate at all, don't trap the user out.
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            isLocked = false
            return
        }

        // Biometrics-first, two-step: the combined `.deviceOwnerAuthentication`
        // policy sometimes skips straight to the passcode sheet; evaluating the
        // biometrics-only policy first guarantees the Face ID / Touch ID prompt,
        // and we chain to the passcode policy on fallback or biometric failure.
        let policy: LAPolicy = canBio ? .deviceOwnerAuthenticationWithBiometrics
                                      : .deviceOwnerAuthentication
        context.evaluatePolicy(policy, localizedReason: "Unlock OTPeek") { [weak self] success, err in
            Task { @MainActor in
                guard let self else { return }
                #if DEBUG
                print("[AppLock] evaluate(\(policy == .deviceOwnerAuthenticationWithBiometrics ? "bio" : "combined")) " +
                      "success=\(success) error=\((err as? LAError).map { "LAError \($0.code.rawValue) \($0.localizedDescription)" } ?? String(describing: err))")
                #endif
                if success {
                    self.authError = nil
                    self.isLocked = false
                    return
                }
                let laCode = (err as? LAError)?.code
                if laCode == .userCancel { return }
                // Face ID failed / user tapped the fallback → offer the passcode.
                if policy == .deviceOwnerAuthenticationWithBiometrics {
                    let passcode = LAContext()
                    passcode.evaluatePolicy(.deviceOwnerAuthentication,
                                            localizedReason: "Unlock OTPeek") { ok, err2 in
                        Task { @MainActor in
                            #if DEBUG
                            print("[AppLock] evaluate(passcode) success=\(ok) " +
                                  "error=\((err2 as? LAError).map { "LAError \($0.code.rawValue) \($0.localizedDescription)" } ?? String(describing: err2))")
                            #endif
                            if ok {
                                self.authError = nil
                                self.isLocked = false
                            } else if let e = err2 as? LAError, e.code != .userCancel {
                                self.authError = e.localizedDescription
                            }
                        }
                    }
                } else if let e = err as? LAError {
                    self.authError = e.localizedDescription
                }
            }
        }
    }

    /// Lock immediately (e.g. from a menu action). Works even when the biometric
    /// toggle is off — unlocking then falls back to the device password.
    public func lockNow() {
        isLocked = true
    }

    /// Re-lock when the feature is toggled on in settings.
    public func settingsChanged() {
        if isEnabled { isLocked = true } else { isLocked = false }
    }

    // MARK: - Auto-lock lifecycle

    public func didResignActive() {
        guard isEnabled, !isLocked else { return }
        backgroundedAt = Date()
    }

    public func didBecomeActive() {
        guard isEnabled, let since = backgroundedAt else { return }
        backgroundedAt = nil
        if Date().timeIntervalSince(since) >= Double(autoLockMinutes) * 60 {
            isLocked = true
        }
    }
}
