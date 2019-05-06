//
//  CKRecord.swift
//  CloudCore
//
//  Created by Vasily Ulianov on 02.02.17.
//  Copyright © 2017 Vasily Ulianov. All rights reserved.
//

import CloudKit

public extension CKRecord {
    convenience init?(archivedData: Data) {
        do {
            let unarchiver = try NSKeyedUnarchiver(forReadingFrom: archivedData)
            unarchiver.requiresSecureCoding = true
            self.init(coder: unarchiver)
        }
        catch {
            return nil
        }
    }

    var encdodedSystemFields: Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        self.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }
}
