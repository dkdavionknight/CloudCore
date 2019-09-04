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

open class Tokens: NSObject, NSSecureCoding {

    public static var supportsSecureCoding: Bool { return true }

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
	
	// MARK: Metadata
	
	/// Load saved Tokens from PersistentStore Metadata. Key is used from `CloudCoreConfig.metadataKeyTokens`
	///
	/// - Returns: previously saved `Token` object, if tokens weren't saved before newly initialized `Tokens` object will be returned
	public static func loadFromContainer(_ container: NSPersistentContainer) -> Tokens {

        func unarchivedTokens(with data: Data) -> Tokens? {
            let unarchiver = NSKeyedUnarchiver(forReadingWith: data)
            unarchiver.requiresSecureCoding = true
            let tokens = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? Tokens
            unarchiver.finishDecoding()
            return tokens
        }

        guard let tokensData = container.persistentStoreCoordinator.metadataValue(forKey: CloudCore.config.metadataKeyTokens) as? Data,
            let tokens = unarchivedTokens(with: tokensData)
            else { return Tokens() }
        return tokens
	}
	
	/// Save tokens to PersistentStore Metadata. Key is used from `CloudCoreConfig.metadataKeyTokens`
	open func saveToContainer(_ container: NSPersistentContainer) {
        let tokensData = NSMutableData()
        let archiver = NSKeyedArchiver(forWritingWith: tokensData)
        archiver.requiresSecureCoding = true
        archiver.encodeRootObject(self)
        archiver.finishEncoding()
        container.persistentStoreCoordinator.setMetadataValue(tokensData, forKey: CloudCore.config.metadataKeyTokens)
	}
	
	// MARK: NSCoding
	
	///	Returns an object initialized from data in a given unarchiver.
	public required init?(coder aDecoder: NSCoder) {
        if let decodedTokensByScope = aDecoder.decodeObject(of: [NSDictionary.self, CKServerChangeToken.self], forKey: ArchiverKey.tokensByDatabaseScope) as? [Int: CKServerChangeToken] {
            self.tokensByDatabaseScope = decodedTokensByScope
        }
        if let decodedTokensByZone = aDecoder.decodeObject(of: [NSDictionary.self, CKRecordZone.ID.self, CKServerChangeToken.self], forKey: ArchiverKey.tokensByRecordZoneID) as? [CKRecordZone.ID: CKServerChangeToken] {
            self.tokensByRecordZoneID = decodedTokensByZone
        }
	}
	
	/// Encodes the receiver using a given archiver.
	open func encode(with aCoder: NSCoder) {
        aCoder.encode(tokensByDatabaseScope, forKey: ArchiverKey.tokensByDatabaseScope)
        aCoder.encode(tokensByRecordZoneID, forKey: ArchiverKey.tokensByRecordZoneID)
	}
	
}
