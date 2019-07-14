//
//  FetchShareRecordOperation.swift
//  CloudCore
//
//  Created by Davion Knight on 30/05/2019.
//

import Foundation
import CloudKit

class FetchShareRecordOperation: Operation {

    private(set) var error: Error?
    private(set) var record: CKRecord?
    private(set) var share: CKShare?

    private let recordID: CKRecord.ID
    private let database: CKDatabase
    private let queue = OperationQueue()

    override func main() {
        super.main()

        let fetchRecordOperation = CKFetchRecordsOperation(recordIDs: [recordID])
        fetchRecordOperation.database = database
        fetchRecordOperation.qualityOfService = .userInteractive
        fetchRecordOperation.desiredKeys = []
        fetchRecordOperation.fetchRecordsCompletionBlock = { [unowned self] in
            self.record = $0?.first?.value
            if ($1 as? CKError)?.code != .operationCancelled { self.error = $1 }
        }

        let fetchShareOperation = CKFetchRecordsOperation()
        fetchShareOperation.database = database
        fetchShareOperation.qualityOfService = .userInteractive
        fetchShareOperation.fetchRecordsCompletionBlock = { [unowned self] in
            self.share = $0?.first?.value as? CKShare
            if ($1 as? CKError)?.code != .operationCancelled { self.error = $1 }
        }

        let adapterOperation = BlockOperation() { [unowned fetchShareOperation, unowned self] in
            if let recordID = self.record?.share?.recordID {
                fetchShareOperation.recordIDs = [recordID]
            }
            else {
                self.queue.cancelAllOperations()
            }
        }

        adapterOperation.addDependency(fetchRecordOperation)
        fetchShareOperation.addDependency(adapterOperation)

        queue.addOperations([fetchRecordOperation, adapterOperation, fetchShareOperation], waitUntilFinished: true)
    }

    // MARK: - Init

    init(recordID: CKRecord.ID, database: CKDatabase) {
        self.recordID = recordID
        self.database = database
        super.init()
    }

}
