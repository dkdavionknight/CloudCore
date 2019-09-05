//
//  NSManagedObjectContext.swift
//  CloudCore
//

import CoreData
import CloudKit

extension NSManagedObjectContext {

    func fetchObject(for record: CKRecord, recordNameKey: String) throws -> NSManagedObject? {
        let fetchRequest = NSFetchRequest<NSManagedObject>(entityName: record.recordType)
        fetchRequest.predicate = NSPredicate(format: "%K == %@", recordNameKey, record.recordID.recordName)
        return try fetch(fetchRequest).first
    }

}
