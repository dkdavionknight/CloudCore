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
    private let database: CKDatabase

    override func main() {
        super.main()

        let fetchRecordOperation = makeFetchRecordOperation(recordID: recordID)
        fetchRecordOperation.desiredKeys = []
        fetchRecordOperation.fetchRecordsCompletionBlock = {
            if let error = $1 {
                self.error = error
            }
            else if let record = $0?.first?.value {
                self.record = record
                if let shareID = record.share?.recordID {
                    self.addFetchShareOperation(shareID: shareID)
                    return
                }
            }
            self.state = .finished
        }
        database.add(fetchRecordOperation)
    }

    private func addFetchShareOperation(shareID: CKRecord.ID) {
        let fetchShareOperation = makeFetchRecordOperation(recordID: shareID)
        fetchShareOperation.fetchRecordsCompletionBlock = {
            if let error = $1 {
                self.error = error
            }
            else if let share = $0?.first?.value as? CKShare {
                self.share = share
            }
            self.state = .finished
        }
        database.add(fetchShareOperation)
    }

    private func makeFetchRecordOperation(recordID: CKRecord.ID) -> CKFetchRecordsOperation {
        let fetchRecordOperation = CKFetchRecordsOperation(recordIDs: [recordID])
        fetchRecordOperation.qualityOfService = .userInteractive
        return fetchRecordOperation
    }

    // MARK: - Init

    init(recordID: CKRecord.ID, database: CKDatabase) {
        self.recordID = recordID
        self.database = database
        super.init()
    }

}
