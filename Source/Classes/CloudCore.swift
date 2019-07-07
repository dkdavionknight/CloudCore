//
//  CloudCore.swift
//  CloudCore
//
//  Created by Vasily Ulianov on 06.02.17.
//  Copyright © 2017 Vasily Ulianov. All rights reserved.
//

import CoreData
import CloudKit

/**
    Main framework class, in most cases you will use only methods from this class, all methods and properties are `static`.

    ## Save to cloud
    On application inialization call `CloudCore.enable(persistentContainer:)` method, so framework will automatically monitor changes at Core Data and upload it to iCloud.

    ### Example
    ```swift
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplicationLaunchOptionsKey: Any]?) -> Bool {
        // Register for push notifications about changes
        application.registerForRemoteNotifications()

        // Enable CloudCore syncing
        CloudCore.delegate = someDelegate // it is recommended to set delegate to track errors
        CloudCore.enable(persistentContainer: persistentContainer)

        return true
    }
    ```

    ## Fetch from cloud
    When CloudKit data is changed **push notification** is posted to an application. You need to handle it and fetch changed data from CloudKit with `CloudCore.pull(using:to:error:completion:)` method.

    ### Example
    ```swift
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable : Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        // Check if it CloudKit's and CloudCore notification
        if CloudCore.isCloudCoreNotification(withUserInfo: userInfo) {
            // Fetch changed data from iCloud
            CloudCore.pull(using: userInfo, to: persistentContainer, error: nil, completion: { (fetchResult) in
                completionHandler(fetchResult.uiBackgroundFetchResult)
            })
        }
    }
    ```

    You can also check for updated data at CloudKit **manually** (e.g. push notifications are not working). Use for that `CloudCore.pull(to:error:completion:)`
*/
open class CloudCore {

    // MARK: - Properties

    private(set) static var coreDataObserver: CoreDataObserver?
    public static var isOnline: Bool {
        get {
            return coreDataObserver?.isOnline ?? false
        }
        set {
            coreDataObserver?.isOnline = newValue
        }
    }

    /// CloudCore configuration, it's recommended to set up before calling any of CloudCore methods. You can read more at `CloudCoreConfig` struct description
    public static var config = CloudCoreConfig()

    /// `Tokens` object, read more at class description. By default variable is loaded from User Defaults.
    public static var tokens: Tokens!

    /// Error and sync actions are reported to that delegate
    public static weak var delegate: CloudCoreDelegate? {
        didSet {
            coreDataObserver?.delegate = delegate
        }
    }

    public typealias NotificationUserInfo = [AnyHashable : Any]

    static private let queue = OperationQueue()

    // MARK: - Methods

    /// Enable CloudKit and Core Data synchronization
    ///
    /// - Parameters:
    ///   - container: `NSPersistentContainer` that will be used to save data
    public static func enable(persistentContainer container: NSPersistentContainer) {
        tokens = Tokens.loadFromContainer(container)

        // Create CloudCore Zone
        let createZoneOperation = CreateCloudCoreZoneOperation()
        createZoneOperation.errorBlock = { _ in queue.cancelAllOperations() }
        queue.addOperation(createZoneOperation)

        let coreDataOperation = BlockOperation()
        coreDataOperation.addExecutionBlock { [unowned coreDataOperation] in
            guard !coreDataOperation.isCancelled else { return }

            // Listen for local changes
            let observer = CoreDataObserver(container: container)
            observer.delegate = delegate
            observer.start()
            coreDataObserver = observer
        }
        coreDataOperation.addDependency(createZoneOperation)
        queue.addOperation(coreDataOperation)

        // Subscribe (subscription may be outdated/removed)
        #if !os(watchOS)
        let subscribeOperation = SubscribeOperation()
        subscribeOperation.errorBlock = { handle(subscriptionError: $0, container: container) }
        subscribeOperation.addDependency(coreDataOperation)
        queue.addOperation(subscribeOperation)
        #endif

        // Fetch updated data (e.g. push notifications weren't received)
        let updateFromCloudOperation = makePullOperation(persistentContainer: container)

        #if !os(watchOS)
        updateFromCloudOperation.addDependency(subscribeOperation)
        #endif

        queue.addOperation(updateFromCloudOperation)
    }

    /// Disables synchronization (push notifications won't be sent also)
    public static func disable() {
        queue.cancelAllOperations()

        coreDataObserver?.stop()
        coreDataObserver = nil

        // FIXME: unsubscribe
    }

    public static func delete(completionHandler: @escaping (Error?) -> Void) {
        let recordZoneOperation = CKModifyRecordZonesOperation(recordZoneIDsToDelete: [config.privateZoneID()])
        recordZoneOperation.qualityOfService = .userInteractive
        recordZoneOperation.modifyRecordZonesCompletionBlock = {
            if $2 == nil {
                CloudCore.config.isDeleting = true
            }
            completionHandler($2)
        }
        config.container.privateCloudDatabase.add(recordZoneOperation)
    }

    // MARK: Fetchers

    /** Fetch changes from one CloudKit database and save it to CoreData from `didReceiveRemoteNotification` method.

     Don't forget to check notification's UserInfo by calling `isCloudCoreNotification(withUserInfo:)`. If incorrect user info is provided `PullResult.noData` will be returned at completion block.

     - Parameters:
         - userInfo: notification's user info, CloudKit database will be extraced from that notification
         - container: `NSPersistentContainer` that will be used to save fetched data
         - error: block will be called every time when error occurs during process
         - completion: `PullResult` enumeration with results of operation
    */
    public static func pull(using userInfo: NotificationUserInfo, to container: NSPersistentContainer, error: ErrorBlock?, completion: @escaping (_ fetchResult: PullResult) -> Void) {
        print("### pull \(String(describing: userInfo))")
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo),
            let _ = self.database(for: notification)
            else {
                completion(.noData)
                return
            }

        DispatchQueue.global(qos: .utility).async {
            if isQueueContainsPullOperation() {
                print("### PullOperation already running")
            }
            else {
                let operation = makePullOperation(persistentContainer: container)
                queue.addOperation(operation)
                print("### PullOperation started from notification")
            }
            completion(PullResult.newData)
        }
    }

    /** Fetch changes from all CloudKit databases and save it to Core Data

     - Parameters:
         - container: `NSPersistentContainer` that will be used to save fetched data
         - error: block will be called every time when error occurs during process
         - completion: `PullResult` enumeration with results of operation
    */
    public static func pull(to container: NSPersistentContainer, completion: (() -> Void)?) {
        print("### pull(to container: NSPersistentContainer, error: ErrorBlock?, completion: (() -> Void)?)")
        if isQueueContainsPullOperation() {
            print("### PullOperation already running")
        }
        else {
            let operation = makePullOperation(persistentContainer: container)
            operation.completionBlock = completion
            queue.addOperation(operation)
        }
    }

    /** Check if notification is CloudKit notification containing CloudCore data

     - Parameter userInfo: userInfo of notification
     - Returns: `true` if notification contains CloudCore data
    */
    public static func isCloudCoreNotification(withUserInfo userInfo: NotificationUserInfo) -> Bool {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) else { return false }
        return database(for: notification) != nil
    }

    static func database(for notification: CKNotification) -> CKDatabase? {
        guard let id = notification.subscriptionID else { return nil }

        switch id {
        case config.subscriptionIDForPrivateDB: return config.container.privateCloudDatabase
        case config.subscriptionIDForSharedDB: return config.container.sharedCloudDatabase
        default: return nil
        }
    }

    // MARK: Share

    public static func getShare(object: NSManagedObject, completionHandler: @escaping ((CKRecord?, CKShare?)?, Error?) -> Void) {
        let recordID = try! object.restoreRecordWithSystemFields(for: .private)!.recordID
        let database = recordID.zoneID.ownerName == CKCurrentUserDefaultName ? config.container.privateCloudDatabase :
            config.container.sharedCloudDatabase
        let operation = FetchShareRecordOperation(recordID: recordID, database: database)
        operation.completionBlock = { [unowned operation] in
            if let error = operation.error {
                completionHandler(nil, error)
            }
            else {
                completionHandler((operation.record, operation.share), nil)
            }
        }
        queue.addOperation(operation)
    }

    public static func share(title: String, imageData: Data?, record: CKRecord, completionHandler: @escaping (CKShare?, CKContainer?, Error?) -> Void) {
        let shareRecord = CKShare(rootRecord: record)
        shareRecord[CKShare.SystemFieldKey.title] = title
        if let imageData = imageData {
            shareRecord[CKShare.SystemFieldKey.thumbnailImageData] = imageData
        }
        let operation = CKModifyRecordsOperation(recordsToSave: [shareRecord, record])
        operation.qualityOfService = .userInteractive
        operation.modifyRecordsCompletionBlock = {
            if let error = $2 {
                completionHandler(nil, nil, error)
            }
            else {
                completionHandler(($0?.first as! CKShare), config.container, nil)
            }
        }
        operation.database = record.recordID.zoneID.ownerName == CKCurrentUserDefaultName ? config.container.privateCloudDatabase :
            config.container.sharedCloudDatabase
        queue.addOperation(operation)
    }

    public static func acceptShare(shareMetadata: CKShare.Metadata, completionHandler: @escaping (Error?) -> Void) {
        let acceptShareOperation: CKAcceptSharesOperation = CKAcceptSharesOperation(shareMetadatas: [shareMetadata])
        acceptShareOperation.qualityOfService = .userInteractive
        acceptShareOperation.acceptSharesCompletionBlock = completionHandler
        config.container.add(acceptShareOperation)
    }

    public static func stopShare(object: NSManagedObject, completionHandler: @escaping (Error?) -> Void) {
        let objectID = object.objectID
        coreDataObserver!.container.performBackgroundTask { context in
            let object = context.object(with: objectID)
            object.setValue(true, forKey: config.defaultAttributeNameMarkedForDeletion)
            var localError: Error?
            do {
                try context.save()
            }
            catch {
                localError = error
            }
            OperationQueue.main.addOperation {
                completionHandler(localError)
            }
        }
    }

    public static func leaveShare(object: NSManagedObject, completionHandler: @escaping (Error?) -> Void) {
        let recordID = try! object.restoreRecordWithSystemFields(for: .private)!.recordID
        let database = recordID.zoneID.ownerName == CKCurrentUserDefaultName ? config.container.privateCloudDatabase :
            config.container.sharedCloudDatabase
        let leaveShareOperation = LeaveShareOperation(recordID: recordID, database: database)
        leaveShareOperation.completionBlock = { [unowned leaveShareOperation] in
            guard !leaveShareOperation.isCancelled || leaveShareOperation.error != nil
                else { completionHandler(leaveShareOperation.error); return }
            stopShare(object: object, completionHandler: completionHandler)
        }
        queue.addOperation(leaveShareOperation)
    }

    static private func handle(subscriptionError: Error, container: NSPersistentContainer) {
        guard let cloudError = subscriptionError as? CKError, let partialErrorValues = cloudError.partialErrorsByItemID?.values else {
            delegate?.error(error: subscriptionError, module: nil)
            return
        }

        // Try to find "Zone Not Found" in partial errors
        for subError in partialErrorValues {
            guard let subError = subError as? CKError else { continue }

            if case .zoneNotFound = subError.code {
                // Zone wasn't found, we need to create it
                self.queue.cancelAllOperations()
                let setupOperation = SetupOperation(container: container, uploadAllData: !(coreDataObserver?.usePersistentHistoryForPush)!)
                self.queue.addOperation(setupOperation)

                return
            }
        }

        delegate?.error(error: subscriptionError, module: nil)
    }

    static private func handle(pullError: Error, container: NSPersistentContainer) {
        guard let cloudError = pullError as? CKError else {
            delegate?.error(error: pullError, module: .some(.pullFromCloud))
            return
        }

        switch cloudError.code {
        // User purged cloud database, we need to delete local cache (according Apple Guidelines)
        // Or our token is expired, we need to refetch everything again
        case .userDeletedZone, .changeTokenExpired: purge(container: container)
        default: delegate?.error(error: cloudError, module: .some(.pullFromCloud))
        }
    }

    static private func purge(container: NSPersistentContainer) {
        disable()
        delegate?.purge(container: container)
    }

    static private func makePullOperation(persistentContainer container: NSPersistentContainer) -> PullOperation {
        let operation = PullOperation(persistentContainer: container)
        operation.errorBlock = { handle(pullError: $0, container: container) }
        operation.purgeBlock = { purge(container: container) }
        return operation
    }

    static private func isQueueContainsPullOperation() -> Bool {
        return queue.operations.contains(where: { $0 is PullOperation })
    }

}
