//
//  FetchRecordZoneChangesOperation.swift
//  CloudCore
//
//  Created by Vasily Ulianov on 09.02.17.
//  Copyright © 2017 Vasily Ulianov. All rights reserved.
//

import CloudKit

class FetchRecordZoneChangesOperation: Operation {
    // Set on init
    let tokens: Tokens
    let recordZoneIDs: [CKRecordZone.ID]
    let database: CKDatabase
    //

    var errorBlock: ((CKRecordZone.ID, Error) -> Void)?
    var recordChangedBlock: ((CKRecord) -> Void)?
    var recordWithIDWasDeletedBlock: ((CKRecord.ID) -> Void)?
    var resetContext: (() -> Void)?

    private let configurationsByRecordZoneID: [CKRecordZone.ID: CKFetchRecordZoneChangesOperation.ZoneConfiguration]
    private let fetchQueue = OperationQueue()

    init(from database: CKDatabase, recordZoneIDs: [CKRecordZone.ID], tokens: Tokens) {
        self.tokens = tokens
        self.database = database
        self.recordZoneIDs = recordZoneIDs

        var configurationsByRecordZoneID = [CKRecordZone.ID: CKFetchRecordZoneChangesOperation.ZoneConfiguration]()
        for zoneID in recordZoneIDs {
            let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
            configuration.previousServerChangeToken = self.tokens.tokensByRecordZoneID[zoneID]
            configurationsByRecordZoneID[zoneID] = configuration
        }
        self.configurationsByRecordZoneID = configurationsByRecordZoneID

        super.init()

        self.name = "FetchRecordZoneChangesOperation"
    }

    override func main() {
        super.main()

        let fetchOperation = self.makeFetchOperation(configurationsByRecordZoneID: configurationsByRecordZoneID)
        fetchQueue.addOperation(fetchOperation)

        fetchQueue.waitUntilAllOperationsAreFinished()
    }

    private func makeFetchOperation(configurationsByRecordZoneID: [CKRecordZone.ID: CKFetchRecordZoneChangesOperation.ZoneConfiguration]) -> CKFetchRecordZoneChangesOperation {
        // Init Fetch Operation
        let fetchOperation = CKFetchRecordZoneChangesOperation(recordZoneIDs: recordZoneIDs, configurationsByRecordZoneID: configurationsByRecordZoneID)
        fetchOperation.fetchAllChanges = false

        fetchOperation.recordChangedBlock = {
            self.recordChangedBlock?($0)
        }
        fetchOperation.recordWithIDWasDeletedBlock = { recordID, _ in
            self.recordWithIDWasDeletedBlock?(recordID)
        }
        fetchOperation.recordZoneFetchCompletionBlock = { zoneId, serverChangeToken, clientChangeTokenData, isMore, error in
            self.tokens.tokensByRecordZoneID[zoneId] = serverChangeToken

            if let error = error {
                self.errorBlock?(zoneId, error)
            }

            if isMore {
                let moreOperation = self.makeFetchOperation(configurationsByRecordZoneID: configurationsByRecordZoneID)
                self.fetchQueue.addOperation(moreOperation)
            }
        }
        fetchOperation.fetchRecordZoneChangesCompletionBlock = {
            guard let error = $0 else { return }

            if let ckError = error as? CKError,
                ckError.code == .networkFailure
            {
                self.resetContext?()
                let retryOperation = self.makeFetchOperation(configurationsByRecordZoneID: configurationsByRecordZoneID)
                self.fetchQueue.addOperation(retryOperation)
            }
            else {
                print("fetchRecordZoneChangesCompletionBlock: \(error)")
            }
        }

        fetchOperation.qualityOfService = self.qualityOfService
        fetchOperation.database = self.database

        return fetchOperation
    }
}
