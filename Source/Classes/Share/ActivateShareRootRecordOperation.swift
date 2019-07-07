//
//  ActivateShareRootRecordOperation.swift
//  CloudCore
//

import Foundation
import CloudKit
import CoreData

class ActivateShareRootRecordOperation: Operation {

    var errorBlock: ErrorBlock?

    private let parentContext: NSManagedObjectContext
    private let share: CKShare
    private let queue = OperationQueue()

    private var rootRecord: CKRecord?

    private func setManagedObject(in context: NSManagedObjectContext) throws {
        guard let record = rootRecord else { return }

        let entityName = record.recordType

        guard let serviceAttributes = NSEntityDescription.entity(forEntityName: entityName, in: context)?.serviceAttributeNames else {
            throw CloudCoreError.missingServiceAttributes(entityName: entityName)
        }

        // Try to find existing objects
        let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: entityName)
        fetchRequest.predicate = NSPredicate(format: "%K == %@ AND %K == %@", serviceAttributes.recordName, record.recordID.recordName,
            serviceAttributes.ownerName, record.recordID.zoneID.ownerName)

        guard let object = try context.fetch(fetchRequest).first as? NSManagedObject else { return }
        object.setValue(false, forKey: serviceAttributes.markedForDeletion)
        try context.save()
    }

    override func main() {
        guard !isCancelled, let url = share.url else { return }

        let fetchOperation = CKFetchShareMetadataOperation(shareURLs: [url])
        fetchOperation.shouldFetchRootRecord = true
        fetchOperation.rootRecordDesiredKeys = []
        fetchOperation.perShareMetadataBlock = { [unowned self] _, shareMetadata, _ in
            self.rootRecord = shareMetadata?.rootRecord
        }

        let updateOperation = BlockOperation()
        updateOperation.addExecutionBlock { [unowned self, unowned updateOperation] in
            if updateOperation.isCancelled { return }

            self.parentContext.performAndWait {
                do {
                    try self.setManagedObject(in: self.parentContext)
                }
                catch {
                    self.errorBlock?(error)
                }
            }
        }
        updateOperation.addDependency(fetchOperation)

        queue.addOperations([fetchOperation, updateOperation], waitUntilFinished: true)
    }

    // MARK: - Init

    init(parentContext: NSManagedObjectContext, share: CKShare) {
        self.parentContext = parentContext
        self.share = share
        super.init()
    }

}
