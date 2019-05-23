//
//  PullOperation.swift
//  CloudCore
//
//  Created by Vasily Ulianov on 13/03/2017.
//  Copyright © 2017 Vasily Ulianov. All rights reserved.
//

import CloudKit
import CoreData

/// An operation that fetches data from CloudKit and saves it to Core Data, you can use it without calling `CloudCore.pull` methods if you application relies on `Operation`
public class PullOperation: Operation {

	/// Private cloud database for the CKContainer specified by CloudCoreConfig
	public static let allDatabases = [
		CloudCore.config.container.publicCloudDatabase,
		CloudCore.config.container.privateCloudDatabase,
		CloudCore.config.container.sharedCloudDatabase
	]

	private let databases: [CKDatabase]
	private let persistentContainer: NSPersistentContainer
    private let tokens: Tokens

	/// Called every time if error occurs
	public var errorBlock: ErrorBlock?
    public var purgeBlock: (() -> Void)?

	private let queue = OperationQueue()

    private var objectsWithMissingReferences = [MissingReferences]()

	/// Initialize operation, it's recommended to set `errorBlock`
	///
	/// - Parameters:
	///   - databases: list of databases to fetch data from (only private is supported now)
	///   - persistentContainer: `NSPersistentContainer` that will be used to save data
	///   - tokens: previously saved `Tokens`, you can generate new ones if you want to fetch all data
	public init(from databases: [CKDatabase] = PullOperation.allDatabases,
                persistentContainer: NSPersistentContainer,
                tokens: Tokens = CloudCore.tokens) {
		self.databases = databases
		self.persistentContainer = persistentContainer
        self.tokens = tokens

		queue.name = "PullQueue"
        queue.maxConcurrentOperationCount = 1
	}

	/// Performs the receiver’s non-concurrent task.
	override public func main() {
		if isCancelled { return }

        print("### PullOperation started")
		CloudCore.delegate?.willSyncFromCloud()

		let backgroundContext = persistentContainer.newBackgroundContext()
		backgroundContext.name = CloudCore.config.pullContextName

        for database in self.databases {
            if database.databaseScope != .public {
                var changedZoneIDs = [CKRecordZone.ID]()
                var deletedZoneIDs = [CKRecordZone.ID]()

                let databaseChangeToken = tokens.tokensByDatabaseScope[database.databaseScope.rawValue]
                let databaseChangeOp = CKFetchDatabaseChangesOperation(previousServerChangeToken: databaseChangeToken)
                databaseChangeOp.database = database
                databaseChangeOp.recordZoneWithIDChangedBlock = { changedZoneIDs.append($0) }
                databaseChangeOp.recordZoneWithIDWasDeletedBlock = { deletedZoneIDs.append($0) }
                databaseChangeOp.fetchDatabaseChangesCompletionBlock = { (changeToken, moreComing, error) in
                    // TODO: error handling?
                    
                    if changedZoneIDs.count > 0 {
                        self.addRecordZoneChangesOperation(recordZoneIDs: changedZoneIDs, database: database, context: backgroundContext)
                    }
                    if deletedZoneIDs.count > 0 {
                        self.deleteRecordsFromDeletedZones(recordZoneIDs: deletedZoneIDs)
                    }

                    self.tokens.tokensByDatabaseScope[database.databaseScope.rawValue] = changeToken
                }
                queue.addOperation(databaseChangeOp)
            }
        }

		queue.waitUntilAllOperationsAreFinished()

		CloudCore.delegate?.didSyncFromCloud()

        print("### PullOperation finished")
    }

    private func addConvertRecordOperation(record: CKRecord, context: NSManagedObjectContext, queue: OperationQueue) {
        // Convert and write CKRecord To NSManagedObject Operation
        let convertOperation = RecordToCoreDataOperation(parentContext: context, record: record)
        convertOperation.errorBlock = { self.errorBlock?($0) }
        queue.addOperation(convertOperation)

        let operation = BlockOperation()
        operation.addExecutionBlock { [unowned operation] in
            if operation.isCancelled || convertOperation.missingObjectsPerEntities.isEmpty { return }
            print("### objectsWithMissingReferences for \(record.recordID.recordName): \(convertOperation.missingObjectsPerEntities)")
            context.perform {
                self.objectsWithMissingReferences.append(convertOperation.missingObjectsPerEntities)
            }
        }
        operation.addDependency(convertOperation)
        queue.addOperation(operation)
    }

    private func addDeleteRecordOperation(recordID: CKRecord.ID, context: NSManagedObjectContext, queue: OperationQueue) {
        // Delete NSManagedObject with specified recordID Operation
        let deleteOperation = DeleteFromCoreDataOperation(parentContext: context, recordID: recordID)
        deleteOperation.errorBlock = { self.errorBlock?($0) }
        queue.addOperation(deleteOperation)
    }

    private func addRecordZoneChangesOperation(recordZoneIDs: [CKRecordZone.ID], database: CKDatabase, context: NSManagedObjectContext) {
		if recordZoneIDs.isEmpty { return }

		let recordZoneChangesOperation = FetchRecordZoneChangesOperation(from: database, recordZoneIDs: recordZoneIDs, tokens: tokens)

		recordZoneChangesOperation.recordChangedBlock = { [unowned recordZoneChangesOperation] in
            self.addConvertRecordOperation(record: $0, context: context, queue: recordZoneChangesOperation.queue)
		}

		recordZoneChangesOperation.recordWithIDWasDeletedBlock = { [unowned recordZoneChangesOperation] in
            self.addDeleteRecordOperation(recordID: $0, context: context, queue: recordZoneChangesOperation.queue)
		}

        recordZoneChangesOperation.errorBlock = {
            if let error = $0 as? CKError,
                error.code == .userDeletedZone || error.code == .changeTokenExpired
            {
                print("### recordZoneChangesOperation cancelAllOperations")
                self.queue.cancelAllOperations()
            }
            self.errorBlock?($0)
        }

        recordZoneChangesOperation.reset = {
            print("### reset")
            self.objectsWithMissingReferences = [MissingReferences]()
            context.performAndWait {
                context.reset()
            }
        }

		queue.addOperation(recordZoneChangesOperation)

        let operation = BlockOperation()
        operation.addExecutionBlock { [unowned operation] in
            if operation.isCancelled { return }

            context.performAndWait {
                do {
                    print("### recordZoneChangesOperation save start")
                    self.processMissingReferences(context: context)
                    try context.save()

                    self.tokens.tokensByRecordZoneID.merge(recordZoneChangesOperation.serverChangeTokens) { $1 }
                    self.tokens.saveToContainer(self.persistentContainer)
                    try context.save()

                    print("### recordZoneChangesOperation saved")

                    if recordZoneChangesOperation.isMoreComing {
                        self.addRecordZoneChangesOperation(recordZoneIDs: recordZoneIDs, database: database, context: context)
                    }
                } catch {
                    self.errorBlock?(error)
                }
            }
        }
        operation.addDependency(recordZoneChangesOperation)
        queue.addOperation(operation)
	}

    private func processMissingReferences(context: NSManagedObjectContext) {
        // iterate over all missing references and fix them, now are all NSManagedObjects created
        for missingReferences in objectsWithMissingReferences {
            for (object, references) in missingReferences {
                guard let serviceAttributes = object.entity.serviceAttributeNames else { continue }

                for (attributeName, recordNames) in references {
                    for recordName in recordNames {
                        guard let relationship = object.entity.relationshipsByName[attributeName], let targetEntityName = relationship.destinationEntity?.name else { continue }

                        // TODO: move to extension
                        let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: targetEntityName)
                        fetchRequest.predicate = NSPredicate(format: serviceAttributes.recordName + " == %@" , recordName)
                        fetchRequest.fetchLimit = 1
                        fetchRequest.includesPropertyValues = false

                        do {
                            let foundObject = try context.fetch(fetchRequest).first as? NSManagedObject

                            if let foundObject = foundObject {
                                if relationship.isToMany {
                                    let set = object.value(forKey: attributeName) as? NSMutableSet ?? NSMutableSet()
                                    set.add(foundObject)
                                    object.setValue(set, forKey: attributeName)
                                } else {
                                    object.setValue(foundObject, forKey: attributeName)
                                }
                            } else {
                                print("warning: object not found " + recordName)
                            }
                        } catch {
                            self.errorBlock?(error)
                        }
                    }
                }
            }
        }
    }

    private func deleteRecordsFromDeletedZones(recordZoneIDs: [CKRecordZone.ID]) {
        print("### deleteRecordsFromDeletedZones")
        guard recordZoneIDs.contains(CloudCore.config.privateZoneID()) else { return }
        purgeBlock?()
    }

}
