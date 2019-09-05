//
//  LeaveShareOperation.swift
//  CloudCore
//
//  Created by Davion Knight on 07/07/2019.
//

import Foundation
import CloudKit

class LeaveShareOperation: Operation {

    private(set) var error: Error?
    private var record: CKRecord?

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

        let leaveShareOperation = CKModifyRecordsOperation()
        leaveShareOperation.database = database
        leaveShareOperation.qualityOfService = .userInteractive
        leaveShareOperation.modifyRecordsCompletionBlock = { [unowned self] in
            if ($2 as? CKError)?.code != .operationCancelled { self.error = $2 }
        }

        let adapterOperation = BlockOperation() { [unowned leaveShareOperation, unowned self] in
            if let recordID = self.record?.share?.recordID {
                leaveShareOperation.recordIDsToDelete = [recordID]
            }
            else {
                self.queue.cancelAllOperations()
            }
        }

        adapterOperation.addDependency(fetchRecordOperation)
        leaveShareOperation.addDependency(adapterOperation)
        
        queue.addOperations([fetchRecordOperation, adapterOperation, leaveShareOperation], waitUntilFinished: true)
    }

    // MARK: - Init

    init(recordID: CKRecord.ID, database: CKDatabase) {
        self.recordID = recordID
        self.database = database
        super.init()
    }

}
