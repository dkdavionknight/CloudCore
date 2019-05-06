//
//  NSPersistentStoreCoordinator.swift
//  CloudCore
//
//  Created by Davion Knight on 05/05/2019.
//

import CoreData

extension NSPersistentStoreCoordinator {

    private var metadata: [String: Any]! {
        get { return persistentStores.first?.metadata }
        set {
            persistentStores.first?.metadata = newValue
            let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
            context.persistentStoreCoordinator = self
            context.performAndWait { try? context.save() }
        }
    }

    func metadataValue(forKey key: String) -> Any? { return metadata[key] }

    func setMetadataValue(_ value: Any?, forKey key: String) {
        var metadata = self.metadata!
        metadata[key] = value
        self.metadata = metadata
    }

}
