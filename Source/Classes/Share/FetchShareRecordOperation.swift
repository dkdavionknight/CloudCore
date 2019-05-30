//
//  FetchShareRecordOperation.swift
//  CloudCore
//

import Foundation
import CloudKit

class FetchShareRecordOperation: AsynchronousOperation {

    private(set) var error: Error?
    private(set) var record: CKRecord?
    private(set) var share: CKShare?

    private let recordID: CKRecord.ID

    override func main() {
        super.main()

        let fetchRecordOperation = makeFetchRecordOperation(recordID: recordID)
        fetchRecordOperation.perRecordCompletionBlock = {
            if let error = $2 {
                self.error = error
            }
            else if let record = $0 {
                self.record = record
                if let shareID = record.share?.recordID {
                    self.addFetchShareOperation(shareID: shareID)
                    return
                }
            }
            self.state = .finished
        }
        CloudCore.config.container.privateCloudDatabase.add(fetchRecordOperation)
    }

    private func addFetchShareOperation(shareID: CKRecord.ID) {
        let fetchShareOperation = makeFetchRecordOperation(recordID: shareID)
        fetchShareOperation.perRecordCompletionBlock = {
            if let error = $2 {
                self.error = error
            }
            else if let share = $0 as? CKShare {
                self.share = share
            }
            self.state = .finished
        }
        CloudCore.config.container.privateCloudDatabase.add(fetchShareOperation)
    }

    private func makeFetchRecordOperation(recordID: CKRecord.ID) -> CKFetchRecordsOperation {
        let fetchRecordOperation = CKFetchRecordsOperation(recordIDs: [recordID])
        fetchRecordOperation.qualityOfService = .userInteractive
        fetchRecordOperation.desiredKeys = []
        return fetchRecordOperation
    }

    // MARK: - Init

    init(recordID: CKRecord.ID) {
        self.recordID = recordID
        super.init()
    }

}
