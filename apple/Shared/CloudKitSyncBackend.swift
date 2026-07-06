import Foundation
import CloudKit

/// 코어의 `SyncBackend`(UniFFI foreign trait) 를 CloudKit 으로 구현한다.
/// 백엔드는 암호화된 불투명 바이트만 옮기며 평문을 절대 보지 않는다.
///
/// - Container: iCloud.com.otpeek.app (see `containerIdentifier`)
/// - Private DB, record type "Vault", recordName "vault"
/// - blob: Data, recordChangeTag 를 etag 로 사용
/// - if_match → save policy .ifServerRecordUnchanged
/// - CKError.serverRecordChanged → OtpError.Conflict
///
/// 트레이트는 블로킹 API 이므로 DispatchSemaphore 로 async CloudKit 을 브리지한다.
/// 반드시 메인 스레드가 아닌 곳에서 호출해야 한다(OtpStore.syncNow 가 보장).
public final class CloudKitSyncBackend: SyncBackend, @unchecked Sendable {

    /// CloudKit container backing sync. Must match the app's
    /// `com.apple.developer.icloud-container-identifiers` entitlement.
    /// A team-unique reverse-DNS id (not the generic `iCloud.com.otpeek.app`,
    /// which is globally taken) so automatic provisioning can create it.
    public static let containerIdentifier = "iCloud.com.otpeek.app"

    private let containerId = CloudKitSyncBackend.containerIdentifier
    private let recordType = "Vault"
    private let recordName = "vault"
    private let blobField = "blob"

    private let database: CKDatabase
    private var recordID: CKRecord.ID { CKRecord.ID(recordName: recordName) }

    public init() {
        self.database = CKContainer(identifier: containerId).privateCloudDatabase
    }

    // MARK: - SyncBackend

    public func fetch() throws -> RemoteBlob? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<RemoteBlob?, OtpError> = .success(nil)

        database.fetch(withRecordID: recordID) { record, error in
            defer { semaphore.signal() }
            if let error = error {
                if Self.isNotFound(error) {
                    result = .success(nil)   // 아직 원격 볼트 없음
                } else {
                    result = .failure(Self.map(error))
                }
                return
            }
            guard let record = record,
                  let data = record[self.blobField] as? Data else {
                result = .success(nil)
                return
            }
            result = .success(RemoteBlob(data: data, etag: record.recordChangeTag))
        }

        semaphore.wait()
        return try result.get()
    }

    public func store(data: Data, ifMatch: String?) throws -> String {
        // 업데이트 대상 레코드 준비.
        let record: CKRecord
        if ifMatch != nil {
            // 기존 레코드를 가져와 서버 변경 태그를 확보한다.
            guard let existing = try fetchRecord() else {
                // 원격이 사라짐 → 충돌로 처리하여 상위에서 재-fetch 하도록.
                throw OtpError.Conflict
            }
            if let tag = existing.recordChangeTag, tag != ifMatch {
                throw OtpError.Conflict
            }
            record = existing
        } else {
            // create-only: 새 레코드. 이미 존재하면 serverRecordChanged 로 충돌.
            record = CKRecord(recordType: recordType, recordID: recordID)
        }
        record[blobField] = data as CKRecordValue

        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<String, OtpError> = .failure(.Backend(msg: "unknown"))

        let op = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
        op.savePolicy = .ifServerRecordUnchanged
        op.isAtomic = true
        op.modifyRecordsResultBlock = { _ in }
        op.perRecordSaveBlock = { _, saveResult in
            switch saveResult {
            case .success(let saved):
                result = .success(saved.recordChangeTag ?? "")
            case .failure(let error):
                result = .failure(Self.map(error))
            }
            semaphore.signal()
        }
        database.add(op)

        semaphore.wait()
        return try result.get()
    }

    // MARK: - Private

    private func fetchRecord() throws -> CKRecord? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<CKRecord?, OtpError> = .success(nil)
        database.fetch(withRecordID: recordID) { record, error in
            defer { semaphore.signal() }
            if let error = error {
                result = Self.isNotFound(error) ? .success(nil) : .failure(Self.map(error))
            } else {
                result = .success(record)
            }
        }
        semaphore.wait()
        return try result.get()
    }

    private static func isNotFound(_ error: Error) -> Bool {
        (error as? CKError)?.code == .unknownItem
    }

    private static func map(_ error: Error) -> OtpError {
        guard let ck = error as? CKError else {
            return .Backend(msg: error.localizedDescription)
        }
        switch ck.code {
        case .serverRecordChanged:
            return .Conflict
        case .notAuthenticated, .accountTemporarilyUnavailable, .permissionFailure:
            return .Auth(msg: ck.localizedDescription)
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy:
            return .Network(msg: ck.localizedDescription)
        default:
            return .Backend(msg: ck.localizedDescription)
        }
    }
}
