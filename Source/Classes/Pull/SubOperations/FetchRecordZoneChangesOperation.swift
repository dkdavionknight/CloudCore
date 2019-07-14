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

    var errorBlock: ((Error) -> Void)?
    var recordChangedBlock: ((CKRecord) -> Void)?
    var recordWithIDWasDeletedBlock: ((CKRecord.ID) -> Void)?
    var reset: (() -> Void)?
    var isMoreComing = false
    var serverChangeTokens = [CKRecordZone.ID: CKServerChangeToken]()

    @available(iOS, introduced: 10.0, deprecated: 12.0)
    @available(OSX, introduced: 10.12, deprecated: 10.14)
    @available(tvOS, introduced: 10.0, deprecated: 12.0)
    @available(watchOS, introduced: 3.0, deprecated: 5.0)
    lazy private var optionsByRecordZoneID = [CKRecordZone.ID: CKFetchRecordZoneChangesOperation.ZoneOptions]()

    @available(iOS 12.0, OSX 10.14, tvOS 12.0, watchOS 5.0, *)
    lazy private var configurationsByRecordZoneID = [CKRecordZone.ID: CKFetchRecordZoneChangesOperation.ZoneConfiguration]()

    let queue = OperationQueue()

    init(from database: CKDatabase, recordZoneIDs: [CKRecordZone.ID], tokens: Tokens) {
        self.tokens = tokens
        self.database = database
        self.recordZoneIDs = recordZoneIDs

        super.init()
        
        if #available(iOS 12.0, OSX 10.14, tvOS 12.0, watchOS 5.0, *) {
            var configurationsByRecordZoneID = [CKRecordZone.ID: CKFetchRecordZoneChangesOperation.ZoneConfiguration]()
            for zoneID in recordZoneIDs {
                let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
                configuration.previousServerChangeToken = self.tokens.tokensByRecordZoneID[zoneID]
                configurationsByRecordZoneID[zoneID] = configuration
            }
            self.configurationsByRecordZoneID = configurationsByRecordZoneID
        }
        else {
            var optionsByRecordZoneID = [CKRecordZone.ID: CKFetchRecordZoneChangesOperation.ZoneOptions]()
            for zoneID in recordZoneIDs {
                let options = CKFetchRecordZoneChangesOperation.ZoneOptions()
                options.previousServerChangeToken = self.tokens.tokensByRecordZoneID[zoneID]
                optionsByRecordZoneID[zoneID] = options
            }
            self.optionsByRecordZoneID = optionsByRecordZoneID
        }

        self.name = "FetchRecordZoneChangesOperation"
    }

    override func main() {
        super.main()

        queue.addOperation(makeFetchOperation())
        queue.waitUntilAllOperationsAreFinished()
    }

    private func makeFetchOperation() -> CKFetchRecordZoneChangesOperation {
        let fetchOperation: CKFetchRecordZoneChangesOperation
        // Init Fetch Operation
        if #available(iOS 12.0, OSX 10.14, tvOS 12.0, watchOS 5.0, *) {
            fetchOperation = CKFetchRecordZoneChangesOperation(recordZoneIDs: recordZoneIDs, configurationsByRecordZoneID: configurationsByRecordZoneID)
        }
        else {
            fetchOperation = CKFetchRecordZoneChangesOperation(recordZoneIDs: recordZoneIDs, optionsByRecordZoneID: optionsByRecordZoneID)
        }

        fetchOperation.recordChangedBlock = { [unowned fetchOperation] in
            if fetchOperation.isCancelled { return }
            print("### recordChangedBlock: \($0)")
            self.recordChangedBlock?($0)
        }
        fetchOperation.recordWithIDWasDeletedBlock = { [unowned fetchOperation] recordID, _ in
            if fetchOperation.isCancelled { return }
            print("### recordWithIDWasDeletedBlock: \(recordID)")
            self.recordWithIDWasDeletedBlock?(recordID)
        }
        fetchOperation.recordZoneFetchCompletionBlock = { [unowned fetchOperation] zoneId, serverChangeToken, clientChangeTokenData, isMoreComing, error in
            if fetchOperation.isCancelled { return }

            print("### recordZoneFetchCompletionBlock: \(zoneId), \(String(describing: serverChangeToken)), \(String(describing: clientChangeTokenData)), \(isMoreComing), \(String(describing: error))")
            if let serverChangeToken = serverChangeToken {
                self.serverChangeTokens[zoneId] = serverChangeToken
            }
            self.isMoreComing = isMoreComing

            if let error = error {
                if let ckError = error as? CKError,
                    ckError.code == .userDeletedZone || ckError.code == .changeTokenExpired
                {
                    self.queue.cancelAllOperations()
                }
                self.errorBlock?(error)
            }
        }
        fetchOperation.fetchRecordZoneChangesCompletionBlock = { [unowned fetchOperation] in
            if fetchOperation.isCancelled { return }

            print("### fetchRecordZoneChangesCompletionBlock: \(String(describing: $0))")
            guard let error = $0 else { return }

            if let ckError = error as? CKError {
                if ckError.code == .networkFailure {
                    self.queue.cancelAllOperations()
                    self.reset?()
                    let retryOperation = self.makeFetchOperation()
                    self.queue.addOperation(retryOperation)
                }
                else if ckError.code == .userDeletedZone || ckError.code == .changeTokenExpired {
                    self.queue.cancelAllOperations()
                    self.errorBlock?(error)
                }
                else {
                    self.errorBlock?(error)
                }
            }
            else {
                self.errorBlock?(error)
            }
        }

        fetchOperation.qualityOfService = self.qualityOfService
        fetchOperation.database = self.database

        return fetchOperation
    }
}
