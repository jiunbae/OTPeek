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
        Task {
            // 앱이 방금 저장한 변경을 반영하도록 읽기 전에 볼트를 연다(내부에서 reload).
            guard let account = loadFirstAccount() else {
                let timeline = Timeline(entries: [OtpEntry.empty], policy: .after(Date().addingTimeInterval(OtpTimeline.retryInterval)))
                completion(timeline)
                return
            }

            // 파비콘이 캐시에 없으면 받아 둔다(설정 on 일 때).
            await FaviconStore.shared.prefetch(account)
            let iconData = OtpTimeline.thumbnail(FaviconProvider.cachedData(for: account))

            // 코드가 바뀌는 순간/경고 진입 순간에만 엔트리를 두고, 다 쓰면 다시 받는다.
            let dates = OtpTimeline.entryDates(from: Date(), periods: [account.period], maxCount: OtpTimeline.singleMaxEntries)
            let entries = dates.map { makeEntry(for: $0, account: account, iconData: iconData) }
            completion(Timeline(entries: entries, policy: .after(OtpTimeline.reloadDate(after: dates, periods: [account.period]))))
        }
    }

    // MARK: - Private

    private func loadFirstAccount() -> OtpAccount? {
        guard let client = WidgetVault.openClient() else { return nil }
        return WidgetVault.firstAccount(from: client)
    }

    private func makeEntry(for date: Date, account: OtpAccount?, iconData: Data? = nil) -> OtpEntry {
        guard let account = account else { return OtpEntry.empty }

        return OtpEntry(
            date: date,
            account: account,
            code: account.generateCode(at: date) ?? "------",
            window: OtpTimeline.window(period: account.period, at: date),
            isWarning: OtpTimeline.isWarning(period: account.period, at: date),
            iconData: iconData
        )
    }
}
