//
//  Scheme.swift
//  CloudCore
//
//  Created by Vasily Ulianov on 02.02.17.
//  Copyright © 2017 Vasily Ulianov. All rights reserved.
//

import Foundation
import CloudKit


/**
	Struct containing CloudCore configuration.

	Changes in configuration are optional and they are not required in most cases.

	## Example

	```swift
	var customConfig = CloudCoreConfig()
	customConfig.publicSubscriptionIDPrefix = "CustomApp"
	CloudCore.config = customConfig
	```
*/
public struct CloudCoreConfig {
	
	// MARK: CloudKit
	
    /// The CKContainer to store CoreData. Set this to a custom container to
    /// support sharing data between multiple apps in an App Group (e.g. iOS and macOS).
    ///
    /// Default value is `CKContainer.default()`
	// `lazy` is set to eliminate crashes during unit-tests
    public lazy var container = CKContainer.default()
    
	/// RecordZone inside private database to store CoreData.
	///
	/// Default value is `CloudCore`
    public var zoneName = "CloudCore"
    public func privateZoneID() -> CKRecordZone.ID {
        return CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    }
	let subscriptionIDForPrivateDB = "CloudCorePrivate"
	let subscriptionIDForSharedDB = "CloudCoreShared"

	// MARK: Core Data
    public let pushContextName = "CloudCorePushContext"
    let pullContextName = "CloudCorePullContext"

    /// Default entity's attribute name for *Record Name* if User Info is not specified
    ///
    /// Default value is `recordName`
    public var defaultAttributeNameRecordName = "recordName"
    
    /// Default entity's attribute name for *Owner Name* if User Info is not specified
    ///
    /// Default value is `recordName`
    public var defaultAttributeNameOwnerName = "ownerName"
    
    /// Default entity's attribute name for *Record Data* if User Info is not specified
    ///
    /// Default value is `recordData`
    public var defaultAttributeNameRecordData = "recordData"

    /// Default entity's attribute name for *Marked For Deletion* if User Info is not specified
    ///
    /// Default value is `markedForDeletion`
    public var defaultAttributeNameMarkedForDeletion = "markedForDeletion"

	// MARK: Metadata
	
	/// Metadata's key to store `Tokens` object
	///
	/// Default value is `CloudCoreTokens`
	public var metadataKeyTokens = "CloudCoreTokens"

    public var isDeleting = false
    
}
