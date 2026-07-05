import WidgetKit
import Foundation

/// 위젯 타임라인 프로바이더.
/// 위젯 프로세스는 Keychain 의 VMK 로 볼트를 열어(openWithKey) 계정을 읽고,
/// 코어의 순수 함수로 시각별 코드를 계산한다. 비밀번호/Argon2 는 사용하지 않는다.
struct OtpTimelineProvider: TimelineProvider {

    func placeholder(in context: Context) -> OtpEntry {
        return OtpEntry.placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (OtpEntry) -> Void) {
        let account = loadFirstAccount()
        completion(makeEntry(for: Date(), account: account))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<OtpEntry>) -> Void) {
        // 앱이 방금 저장한 변경을 반영하도록 읽기 전에 볼트를 연다(내부에서 reload).
        let account = loadFirstAccount()

        guard account != nil else {
            let timeline = Timeline(entries: [OtpEntry.empty], policy: .after(Date().addingTimeInterval(300)))
            completion(timeline)
            return
        }

        var entries: [OtpEntry] = []
        let currentDate = Date()
        for secondOffset in stride(from: 0, to: 300, by: 1) {
            let entryDate = Calendar.current.date(byAdding: .second, value: secondOffset, to: currentDate)!
            entries.append(makeEntry(for: entryDate, account: account))
        }

        let refreshDate = Calendar.current.date(byAdding: .minute, value: 5, to: currentDate)!
        completion(Timeline(entries: entries, policy: .after(refreshDate)))
    }

    // MARK: - Private

    private func loadFirstAccount() -> OtpAccount? {
        guard let client = WidgetVault.openClient() else { return nil }
        return WidgetVault.firstAccount(from: client)
    }

    private func makeEntry(for date: Date, account: OtpAccount?) -> OtpEntry {
        guard let account = account else { return OtpEntry.empty }

        let code = account.generateCode(at: date) ?? "------"
        let progress = OtpGenerator.getProgress(period: account.period, date: date)
        let remainingSeconds = OtpGenerator.getRemainingSeconds(period: account.period, date: date)

        return OtpEntry(
            date: date,
            account: account,
            code: code,
            progress: progress,
            remainingSeconds: remainingSeconds
        )
    }
}
