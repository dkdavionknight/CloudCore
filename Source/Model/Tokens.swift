//
//  Tokens.swift
//  CloudCore
//
//  Created by Vasily Ulianov on 07.02.17.
//  Copyright © 2017 Vasily Ulianov. All rights reserved.
//

import CloudKit
import CoreData

/**
 CloudCore's class for storing global `CKToken` objects. Framework uses one to download only changed data (smart-sync).

 Framework stores tokens in 2 places:

 * singleton `Tokens` object in `CloudCore.tokens`
 * tokens per record inside *Record Data* attribute, it is managed automatically you don't need to take any actions about that token
 */

open class Tokens: NSObject, NSCoding {

    var tokensByDatabaseScope = [Int: CKServerChangeToken]()
    var tokensByRecordZoneID = [CKRecordZone.ID: CKServerChangeToken]()

    private struct ArchiverKey {
        static let tokensByDatabaseScope = "tokensByDatabaseScope"
        static let tokensByRecordZoneID = "tokensByRecordZoneID"
    }

    /// Create fresh object without any Tokens inside. Can be used to fetch full data.
    public override init() {
        super.init()
    }

    // MARK: User Defaults

    /// Load saved Tokens from PersistentStore Metadata. Key is used from `CloudCoreConfig.userDefaultsKeyTokens`
    ///
    /// - Returns: previously saved `Token` object, if tokens weren't saved before newly initialized `Tokens` object will be returned
    public static func loadFromContainer(_ container: NSPersistentContainer) -> Tokens {
        guard let tokensData = container.persistentStoreCoordinator.metadataValue(forKey: CloudCore.config.metadataKeyTokens) as? Data,
            let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: tokensData)
            else { return Tokens() }

        unarchiver.requiresSecureCoding = false
        return unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? Tokens ?? Tokens()
    }

    /// Save tokens to PersistentStore Metadata. Key is used from `CloudCoreConfig.userDefaultsKeyTokens`
    open func saveToContainer(_ container: NSPersistentContainer) {
        let tokensData = try? NSKeyedArchiver.archivedData(withRootObject: self, requiringSecureCoding: false)
        container.persistentStoreCoordinator.setMetadataValue(tokensData, forKey: CloudCore.config.metadataKeyTokens)
    }

    // MARK: NSCoding

    ///    Returns an object initialized from data in a given unarchiver.
    public required init?(coder aDecoder: NSCoder) {
        if let decodedTokensByScope = aDecoder.decodeObject(forKey: ArchiverKey.tokensByDatabaseScope) as? [Int: CKServerChangeToken] {
            self.tokensByDatabaseScope = decodedTokensByScope
        }
        if let decodedTokensByZone = aDecoder.decodeObject(forKey: ArchiverKey.tokensByRecordZoneID) as? [CKRecordZone.ID: CKServerChangeToken] {
            self.tokensByRecordZoneID = decodedTokensByZone
        }
    }

    /// Encodes the receiver using a given archiver.
    open func encode(with aCoder: NSCoder) {
        aCoder.encode(tokensByDatabaseScope, forKey: ArchiverKey.tokensByDatabaseScope)
        aCoder.encode(tokensByRecordZoneID, forKey: ArchiverKey.tokensByRecordZoneID)
    }

}
