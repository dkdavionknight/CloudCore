//
//  CoreDataChangesListener.swift
//  CloudCore
//
//  Created by Vasily Ulianov on 02.02.17.
//  Copyright © 2017 Vasily Ulianov. All rights reserved.
//

import Foundation
import CoreData
import CloudKit

/// Class responsible for taking action on Core Data changes
class CoreDataObserver {
    let container: NSPersistentContainer

    let converter = ObjectToRecordConverter()
    let pushOperationQueue = PushOperationQueue()

    let cloudContextName = "CloudCoreSync"

    // Used for errors delegation
    weak var delegate: CloudCoreDelegate?

    var usePersistentHistoryForPush = false
    var isOnline = true {
        didSet {
            if isOnline != oldValue && isOnline == true && usePersistentHistoryForPush == true {
                processPersistentHistory()
            }
        }
    }

    public init(container: NSPersistentContainer) {
        self.container = container
        converter.errorBlock = { [weak self] in
            self?.delegate?.error(error: $0, module: .some(.pushToCloud))
        }

        if #available(iOS 11.0, watchOS 4.0, tvOS 11.0, OSX 10.13, *) {
            let storeDescription = container.persistentStoreDescriptions.first
            if let persistentHistoryNumber = storeDescription?.options[NSPersistentHistoryTrackingKey] as? NSNumber
            {
                usePersistentHistoryForPush = persistentHistoryNumber.boolValue
            }

            if usePersistentHistoryForPush {
                processPersistentHistory()
            }
        }
    }

    /// Observe Core Data willSave and didSave notifications
    func start() {
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(self.willSave(notification:)),
                                               name: .NSManagedObjectContextWillSave,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(self.didSave(notification:)),
                                               name: .NSManagedObjectContextDidSave,
                                               object: nil)
    }

    /// Remove Core Data observers
    func stop() {
        NotificationCenter.default.removeObserver(self)
    }

    deinit {
        stop()
    }

    func shouldProcess(_ context: NSManagedObjectContext) -> Bool {
        // Ignore saves that are generated by PullController
        if context.name != CloudCore.config.pushContextName { return false }

        // Upload only for changes in root context that will be saved to persistentStore
        if context.parent != nil { return false }

        return true
    }

    func processChanges() -> Bool {
        var success = true

        CloudCore.delegate?.willSyncToCloud()

        let backgroundContext = container.newBackgroundContext()
        backgroundContext.name = cloudContextName

        let records = converter.processPendingOperations(in: backgroundContext)
        pushOperationQueue.saveBlock = { record in
            backgroundContext.performAndWait {
                self.updateRecordData(for: record, context: backgroundContext)
            }
        }
        pushOperationQueue.errorBlock = {
            self.handle(error: $0, parentContext: backgroundContext)
            success = false
        }
        pushOperationQueue.addOperations(recordsToSave: records.recordsToSave, recordIDsToDelete: records.recordIDsToDelete)
        pushOperationQueue.waitUntilAllOperationsAreFinished()

        if success {
            do {
                if backgroundContext.hasChanges {
                    try backgroundContext.save()
                }
            } catch {
                delegate?.error(error: error, module: .some(.pushToCloud))
                success = false
            }
        }

        CloudCore.delegate?.didSyncToCloud()

        return success
    }

    @objc private func willSave(notification: Notification) {
        guard let context = notification.object as? NSManagedObjectContext else { return }
        guard shouldProcess(context) else { return }

        if usePersistentHistoryForPush {
            context.insertedObjects.forEach { (inserted) in
                if let serviceAttributeNames = inserted.entity.serviceAttributeNames {
                    for scope in serviceAttributeNames.scopes {
                        let _ = try? inserted.setRecordInformation(for: scope)
                    }
                }
            }
        } else {
            converter.prepareOperationsFor(inserted: context.insertedObjects,
                                           updated: context.updatedObjects,
                                           deleted: context.deletedObjects)
        }
    }

    @objc private func didSave(notification: Notification) {
        guard let context = notification.object as? NSManagedObjectContext else { return }
        guard shouldProcess(context) else { return }

        if usePersistentHistoryForPush == true {
            DispatchQueue.main.async { [weak self] in
                guard let observer = self else { return }
                observer.processPersistentHistory()
            }
        } else {
            guard converter.hasPendingOperations else { return }

            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let observer = self else { return }
                _ = observer.processChanges()
            }
        }
    }

    func processPersistentHistory() {
        #if os(iOS)
        guard isOnline else { return }
        #endif

        if #available(iOS 11.0, watchOSApplicationExtension 4.0, tvOS 11.0, OSX 10.13, *) {

            func process(_ transaction: NSPersistentHistoryTransaction, in moc: NSManagedObjectContext) -> Bool {
                var success = true

                if transaction.contextName != CloudCore.config.pushContextName { return success }

                if let changes = transaction.changes {
                    var insertedObjects = Set<NSManagedObject>()
                    var updatedObject = Set<NSManagedObject>()
                    var deletedRecordIDs: [RecordIDWithDatabase] = []

                    for change in changes {
                        switch change.changeType {
                        case .insert:
                            if let inserted = try? moc.existingObject(with: change.changedObjectID) {
                                insertedObjects.insert(inserted)
                            }

                        case .update:
                            if let inserted = try? moc.existingObject(with: change.changedObjectID) {
                                if let updatedProperties = change.updatedProperties {
                                    let updatedPropertyNames: [String] = updatedProperties
                                        .filter {
                                            guard let description = $0 as? NSRelationshipDescription else { return true }
                                            return !description.isToMany || description.isCloudCoreEnabled
                                        }
                                        .map { $0.name }
                                    inserted.updatedPropertyNames = updatedPropertyNames
                                }
                                if !(inserted.updatedPropertyNames?.isEmpty ?? true) {
                                    updatedObject.insert(inserted)
                                }
                            }

                        case .delete:
                            if change.tombstone != nil {
                                if let recordData = change.tombstone!["recordData"] as? Data {
                                    let ckRecord = CKRecord(archivedData: recordData)
                                    let database = ckRecord?.recordID.zoneID.ownerName == CKCurrentUserDefaultName ? CloudCore.config.container.privateCloudDatabase : CloudCore.config.container.sharedCloudDatabase
                                    let recordIDWithDatabase = RecordIDWithDatabase(recordID: (ckRecord?.recordID)!, database: database)
                                    deletedRecordIDs.append(recordIDWithDatabase)
                                }
                            }
                        @unknown default:
                            fatalError()
                        }
                    }

                    self.converter.prepareOperationsFor(inserted: insertedObjects,
                                                        updated: updatedObject,
                                                        deleted: deletedRecordIDs)

                    try? moc.save()

                    if self.converter.hasPendingOperations {
                        success = self.processChanges()
                    }
                }

                return success
            }

            container.performBackgroundTask { (moc) in
                let key = "lastPersistentHistoryTokenKey"
                var token: NSPersistentHistoryToken?
                if let data = moc.persistentStoreCoordinator!.metadataValue(forKey: key) as? Data {
                     token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSPersistentHistoryToken.self, from: data)
                }
                let historyRequest = NSPersistentHistoryChangeRequest.fetchHistory(after: token)
                do {
                    let historyResult = try moc.execute(historyRequest) as! NSPersistentHistoryResult

                    if let history = historyResult.result as? [NSPersistentHistoryTransaction] {
                        for transaction in history {
                            if process(transaction, in: moc) {
                                let deleteRequest = NSPersistentHistoryChangeRequest.deleteHistory(before: transaction)
                                try moc.execute(deleteRequest)

                                let data = try NSKeyedArchiver.archivedData(withRootObject: transaction.token, requiringSecureCoding: true)
                                moc.persistentStoreCoordinator!.setMetadataValue(data, forKey: key)
                            } else {
                                break
                            }
                        }
                    }
                } catch {
                    let nserror = error as NSError
                    switch nserror.code {
                    case NSPersistentHistoryTokenExpiredError:
                        moc.persistentStoreCoordinator!.setMetadataValue(nil, forKey: key)
                    default:
                        fatalError("Unresolved error \(nserror), \(nserror.userInfo)")
                    }
                }
            }
        }
    }

    private func updateRecordData(for record: CKRecord, context: NSManagedObjectContext) {
        guard let entity = container.managedObjectModel.entitiesByName[record.recordType],
            let serviceAttributeNames = entity.serviceAttributeNames,
            let object = try? context.fetchObject(for: record, recordNameKey: serviceAttributeNames.recordName)
            else { return }
        object.setValue(record.encdodedSystemFields, forKey: serviceAttributeNames.recordData)
    }

    private func handle(error: Error, parentContext: NSManagedObjectContext) {
        guard let cloudError = error as? CKError else {
            delegate?.error(error: error, module: .some(.pushToCloud))
            return
        }

        switch cloudError.code {
        // Zone was accidentally deleted (NOT PURGED), we need to reupload all data accroding Apple Guidelines
        case .zoneNotFound:
            pushOperationQueue.cancelAllOperations()

            // Create CloudCore Zone
            let createZoneOperation = CreateCloudCoreZoneOperation()
            createZoneOperation.errorBlock = {
                self.delegate?.error(error: $0, module: .some(.pushToCloud))
                self.pushOperationQueue.cancelAllOperations()
            }

            // Subscribe operation
            #if !os(watchOS)
                let subscribeOperation = SubscribeOperation()
                subscribeOperation.errorBlock = { self.delegate?.error(error: $0, module: .some(.pushToCloud)) }
                subscribeOperation.addDependency(createZoneOperation)
                pushOperationQueue.addOperation(subscribeOperation)
            #endif

            // Upload all local data
            let uploadOperation = PushAllLocalDataOperation(parentContext: parentContext, managedObjectModel: container.managedObjectModel)
            uploadOperation.errorBlock = { self.delegate?.error(error: $0, module: .some(.pushToCloud)) }

            pushOperationQueue.addOperations([createZoneOperation, uploadOperation], waitUntilFinished: true)
        case .operationCancelled: return
        default: delegate?.error(error: cloudError, module: .some(.pushToCloud))
        }
    }

}
