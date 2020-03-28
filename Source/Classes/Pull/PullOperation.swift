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
                databaseChangeOp.recordZoneWithIDChangedBlock = { (recordZoneID) in
                    changedZoneIDs.append(recordZoneID)
                }
                databaseChangeOp.recordZoneWithIDWasDeletedBlock = { (recordZoneID) in
                    deletedZoneIDs.append(recordZoneID)
                }
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
        print("### PullOperation finished")

		CloudCore.delegate?.didSyncFromCloud()
	}

    private func addConvertRecordOperation(record: CKRecord, context: NSManagedObjectContext, queue: OperationQueue) {
        // Convert and write CKRecord To NSManagedObject Operation
        let convertOperation = RecordToCoreDataOperation(parentContext: context, record: record)
        convertOperation.errorBlock = { self.errorBlock?($0) }
        queue.addOperation(convertOperation)

        let operation = BlockOperation()
        operation.addExecutionBlock {
            guard !operation.isCancelled else { return }
            print("### objectsWithMissingReferences: \(convertOperation.missingObjectsPerEntities)")
            self.objectsWithMissingReferences.append(convertOperation.missingObjectsPerEntities)
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

		recordZoneChangesOperation.recordChangedBlock = {
            self.addConvertRecordOperation(record: $0, context: context, queue: recordZoneChangesOperation.queue)
		}

		recordZoneChangesOperation.recordWithIDWasDeletedBlock = {
            self.addDeleteRecordOperation(recordID: $0, context: context, queue: recordZoneChangesOperation.queue)
		}

		recordZoneChangesOperation.errorBlock = { zoneID, error in
			self.handle(recordZoneChangesError: error, in: zoneID, database: database, context: context)
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
        operation.addExecutionBlock {
            guard !operation.isCancelled else { return }

            context.performAndWait {
                do {
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
        persistentContainer.performBackgroundTask { (moc) in
            for entity in self.persistentContainer.managedObjectModel.entities {
                if let serviceAttributes = entity.serviceAttributeNames {
                    for recordZoneID in recordZoneIDs {
                        do {
                            let request = NSFetchRequest<NSFetchRequestResult>(entityName: entity.name!)
                            request.predicate = NSPredicate(format: "%K == %@", serviceAttributes.ownerName, recordZoneID.ownerName)
                            let results = try moc.fetch(request) as! [NSManagedObject]
                            for object in results {
                                moc.delete(object)
                            }
                        } catch {
                            print("Unexpected error: \(error).")
                        }
                    }
                }
            }

            do {
                try moc.save()
            } catch {
                print("Unexpected error: \(error).")
            }
        }
    }

    private func handle(recordZoneChangesError: Error, in zoneId: CKRecordZone.ID, database: CKDatabase, context: NSManagedObjectContext) {
		guard let cloudError = recordZoneChangesError as? CKError else {
			errorBlock?(recordZoneChangesError)
			return
		}

		switch cloudError.code {
		// User purged cloud database, we need to delete local cache (according Apple Guidelines)
		case .userDeletedZone:
			queue.cancelAllOperations()

			let purgeOperation = PurgeLocalDatabaseOperation(parentContext: context, managedObjectModel: persistentContainer.managedObjectModel)
			purgeOperation.errorBlock = errorBlock
			queue.addOperation(purgeOperation)

		// Our token is expired, we need to refetch everything again
		case .changeTokenExpired:
			tokens.tokensByRecordZoneID[zoneId] = nil
			self.addRecordZoneChangesOperation(recordZoneIDs: [zoneId], database: database, context: context)
		default: errorBlock?(cloudError)
		}
	}

}
