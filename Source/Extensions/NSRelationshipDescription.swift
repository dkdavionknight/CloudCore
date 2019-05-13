//
//  NSRelationshipDescription.swift
//  CloudCore
//
//  Created by Davion Knight on 13/05/2019.
//

import CoreData

extension NSRelationshipDescription {

    var isCloudCoreEnabled: Bool {
        return NSString(string: userInfo?["CloudCoreEnabled"] as? String ?? "").boolValue
    }

}
