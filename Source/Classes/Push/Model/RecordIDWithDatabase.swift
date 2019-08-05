//
//  RecordIDWithDatabase.swift
//  CloudCore
//
//  Created by Vasily Ulianov on 13/03/2017.
//  Copyright © 2017 Vasily Ulianov. All rights reserved.
//

import CloudKit

struct RecordIDWithDatabase {
    let recordID: CKRecord.ID
	let database: CKDatabase
}
