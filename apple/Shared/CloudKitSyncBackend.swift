import Foundation
import CloudKit
import os

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
    /// `com.apple.developer.icloud-container-identifiers` entitlement. The
    /// container is provisioned under the team; its `Vault` record type must be
    /// deployed to the Production schema (Development auto-creates types, but
    /// Production — which TestFlight/App Store builds use — does not).
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
        guard let record = try fetchRecord() else { return nil }
        guard let data = record[blobField] as? Data, let tag = record.recordChangeTag else {
            throw OtpError.Backend(msg: "The iCloud vault record is missing its data or version.")
        }
        return RemoteBlob(data: data, etag: tag)
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
            if existing.recordChangeTag != ifMatch {
                throw OtpError.Conflict
            }
            record = existing
        } else {
            // create-only: 새 레코드. 이미 존재하면 serverRecordChanged 로 충돌.
            record = CKRecord(recordType: recordType, recordID: recordID)
        }
        record[blobField] = data as CKRecordValue

        let savedRecord = OSAllocatedUnfairLock(initialState: Optional<Result<String, Error>>.none)
        let completion = CloudOperationResult<String>()
        let op = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
        op.savePolicy = .ifServerRecordUnchanged
        op.isAtomic = true
        op.perRecordSaveBlock = { _, result in
            savedRecord.withLock { outcome in
                outcome = result.flatMap { saved in
                    guard let tag = saved.recordChangeTag else {
                        return .failure(OtpError.Backend(msg: "The saved iCloud vault has no version."))
                    }
                    return .success(tag)
                }
            }
        }
        let id = recordID
        op.modifyRecordsResultBlock = { result in
            let saved = savedRecord.withLock { $0 }
            switch result {
            case .success:
                completion.finish(saved?.mapError { Self.map($0) }
                    ?? .failure(.Backend(msg: "iCloud returned no vault save result.")))
            case .failure(let error):
                let recordError = (error as? CKError)?.partialErrorsByItemID?[id]
                if case .failure(let error)? = saved {
                    completion.finish(.failure(Self.map(error)))
                } else {
                    completion.finish(.failure(Self.map(recordError ?? error)))
                }
            }
        }
        return try run(op, waitingFor: completion)
    }

    // MARK: - Private

    private func fetchRecord() throws -> CKRecord? {
        let completion = CloudOperationResult<CKRecord?>()
        let id = recordID
        let op = CKFetchRecordsOperation(recordIDs: [id])
        let fetchedRecord = OSAllocatedUnfairLock(initialState: Optional<Result<CKRecord, Error>>.none)
        op.perRecordResultBlock = { _, result in
            fetchedRecord.withLock { $0 = result }
        }
        op.fetchRecordsResultBlock = { result in
            let fetched = fetchedRecord.withLock { $0 }
            let outcome: Result<CKRecord, Error>
            if let fetched {
                outcome = fetched
            } else if case .failure(let error) = result {
                outcome = .failure((error as? CKError)?.partialErrorsByItemID?[id] ?? error)
            } else {
                outcome = .failure(OtpError.Backend(msg: "iCloud returned no vault fetch result."))
            }
            switch outcome {
            case .success(let record):
                completion.finish(.success(record))
            case .failure(let error):
                completion.finish(Self.isNotFound(error) ? .success(nil) : .failure(Self.map(error)))
            }
        }
        return try run(op, waitingFor: completion)
    }

    private func run<Value>(_ operation: CKDatabaseOperation, waitingFor result: CloudOperationResult<Value>) throws -> Value {
        let configuration = CKOperation.Configuration()
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 25
        operation.configuration = configuration
        database.add(operation)
        return try result.wait {
            operation.cancel()
        }
    }

    private static func isNotFound(_ error: Error) -> Bool {
        (error as? CKError)?.code == .unknownItem
    }

    private static func map(_ error: Error) -> OtpError {
        if let otp = error as? OtpError { return otp }
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

/// CloudKit may deliver a callback after a timeout. Keep the result and semaphore
/// alive with the callback and synchronize access across queues.
private final class CloudOperationResult<Value: Sendable>: Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let result = OSAllocatedUnfairLock(initialState: Optional<Result<Value, OtpError>>.none)

    func finish(_ outcome: Result<Value, OtpError>) {
        result.withLock { $0 = outcome }
        semaphore.signal()
    }

    func wait(onTimeout: () -> Void) throws -> Value {
        guard semaphore.wait(timeout: .now() + 30) == .success else {
            onTimeout()
            throw OtpError.Network(msg: "iCloud did not respond in time.")
        }
        guard let outcome = result.withLock({ $0 }) else {
            throw OtpError.Backend(msg: "iCloud returned no operation result.")
        }
        return try outcome.get()
    }
}
