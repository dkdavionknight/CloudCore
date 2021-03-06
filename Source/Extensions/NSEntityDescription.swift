//
//  NSEntityDescription.swift
//  CloudCore
//
//  Created by Vasily Ulianov on 07.02.17.
//  Copyright © 2017 Vasily Ulianov. All rights reserved.
//

import CoreData
import CloudKit

extension NSEntityDescription {
	var serviceAttributeNames: ServiceAttributeNames? {
		guard let entityName = name else { return nil }
		
		let attributeNamesFromUserInfo = parseAttributeNamesFromUserInfo()
		
		// Get required attributes
        // Record Name
        let recordNameAttribute: String
        if let recordNameUserInfoName = attributeNamesFromUserInfo.recordName {
            recordNameAttribute = recordNameUserInfoName
        } else {
            // Last chance: try to find default attribute name in entity
            if attributesByName.keys.contains(CloudCore.config.defaultAttributeNameRecordName) {
                recordNameAttribute = CloudCore.config.defaultAttributeNameRecordName
            } else {
                return nil
            }
        }
        
        // Owner Name
        let ownerNameAttribute: String
        if let ownerNameUserInfoName = attributeNamesFromUserInfo.ownerName {
            ownerNameAttribute = ownerNameUserInfoName
        } else {
            // Last chance: try to find default attribute name in entity
            if attributesByName.keys.contains(CloudCore.config.defaultAttributeNameOwnerName) {
                ownerNameAttribute = CloudCore.config.defaultAttributeNameOwnerName
            } else {
                return nil
            }
        }
        
        // Record Data
        let recordDataAttribute: String
        if let recordDataUserInfoName = attributeNamesFromUserInfo.recordData {
            recordDataAttribute = recordDataUserInfoName
        } else {
            // Last chance: try to find default attribute name in entity
            if attributesByName.keys.contains(CloudCore.config.defaultAttributeNameRecordData) {
                recordDataAttribute = CloudCore.config.defaultAttributeNameRecordData
            } else {
                return nil
            }
        }

        // Mark For Deletion
        let markedForDeletionAttribute: String
        if let markedForDeletionUserInfoName = attributeNamesFromUserInfo.markedForDeletion {
            markedForDeletionAttribute = markedForDeletionUserInfoName
        } else {
            // Use default attribute name
            markedForDeletionAttribute = CloudCore.config.defaultAttributeNameMarkedForDeletion
        }

        return ServiceAttributeNames(entityName: entityName,
                                     scopes: attributeNamesFromUserInfo.scopes,
                                     recordName: recordNameAttribute,
                                     ownerName: ownerNameAttribute,
                                     recordData: recordDataAttribute,
                                     markedForDeletion: markedForDeletionAttribute)
	}
	
	/// Parse data from User Info dictionary
    private func parseAttributeNamesFromUserInfo() -> (scopes: [CKDatabase.Scope], recordName: String?, ownerName: String?, recordData: String?, markedForDeletion: String?) {
        var scopes: [CKDatabase.Scope] = []
        var recordNameAttribute: String?
        var ownerNameAttribute: String?
        var recordDataAttribute: String?
        var markedForDeletionAttribute: String?

        func parse(_ attributeName: String, _ userInfo: [AnyHashable: Any]) {
            for (key, value) in userInfo {
                guard let key = key as? String,
                    let value = value as? String else { continue }
                
                if key == ServiceAttributeNames.keyType {
                    switch value {
                    case ServiceAttributeNames.valueRecordName: recordNameAttribute = attributeName
                    case ServiceAttributeNames.valueOwnerName: ownerNameAttribute = attributeName
                    case ServiceAttributeNames.valueRecordData: recordDataAttribute = attributeName
                    case ServiceAttributeNames.valueMarkedForDeletion: markedForDeletionAttribute = attributeName
                    default: continue
                    }
                } else if key == ServiceAttributeNames.keyScopes {
                    let scopeStrings = value.components(separatedBy: ",")
                    for scopeString in scopeStrings {
                        switch scopeString {
                        case "private":
                            scopes.append(.private)
                        default:
                            break
                        }
                    }
                }
            }
        }
        
        if let userInfo = self.userInfo {
            parse("", userInfo)
        }
        
		// In attribute
		for (attributeName, attributeDescription) in self.attributesByName {
			guard let userInfo = attributeDescription.userInfo else { continue }
			parse(attributeName, userInfo)
		}
		
		return (scopes, recordNameAttribute, ownerNameAttribute, recordDataAttribute, markedForDeletionAttribute)
	}
	
}
