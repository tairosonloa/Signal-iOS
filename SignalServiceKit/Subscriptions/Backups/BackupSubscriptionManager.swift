//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import StoreKit
import LibSignalClient

/// Responsible for In-App Purchases (IAP) that grant access to paid-tier Backups.
///
/// - Note
/// Backup payments are done via IAP using Apple as the payment processor, and
/// consequently payments management is done via Apple ID management in the iOS
/// Settings app rather than in-app UI.
///
/// - Note
/// An IAP subscription may only be started on a primary. However, that primary
/// may or may not be the same device as our current primary; that primary may
/// or may not even be an iOS device if the user migrated from Android to iOS.
///
/// - Important
/// Not to be confused with ``DonationSubscriptionManager``, which does many
/// similar things but designed around donations and profile badges.
public protocol BackupSubscriptionManager {
    typealias PurchaseResult = BackupSubscription.PurchaseResult
    typealias IAPSubscriberData = BackupSubscription.IAPSubscriberData

    /// Attempts to purchase and redeem a Backups subscription for the first
    /// time, via StoreKit IAP.
    ///
    /// - Note
    /// While this should be called only for users who do not currently have a
    /// Backups subscription, StoreKit handles already-subscribed users
    /// gracefully by showing explanatory UI.
    ///
    /// - Note
    /// This method will finish successfully
    func purchaseNewSubscription() async throws -> PurchaseResult

    /// Redeems a StoreKit Backups subscription with Signal servers for access
    /// to paid-tier Backup credentials, if there exists a StoreKit transaction
    /// we have not yet redeemed.
    ///
    /// - Note
    /// This method serializes callers, is safe to call repeatedly, and returns
    /// quickly if there is not a transaction we have yet to redeem.
    func redeemSubscriptionIfNecessary() async throws

    func getIAPSubscriberData(tx: DBReadTransaction) -> IAPSubscriberData?

    /// - Important
    /// Generally, this type generates and manages the `iapSubscriberData`
    /// internally. The exception is "restoring" `iapSubscriberData` preserved
    /// in external storage and considered authoritative, such as one in Storage
    /// Service or a Backup.
    func restoreIAPSubscriberData(_ iapSubscriberData: IAPSubscriberData, tx: DBWriteTransaction)
}

public enum BackupSubscription {

    /// Bundles data associated with a user's IAP subscription.
    public struct IAPSubscriberData {
        /// An identifier generated by an IAP provider identifying the user's
        /// subscription in the IAP system.
        public enum IAPSubscriptionId {
            /// An `originalTransactionId` from an iOS StoreKit `Transaction`.
            case originalTransactionId(UInt64)

            /// A `purchaseToken` identifying an Android Play Store subscription.
            case purchaseToken(String)
        }

        /// A client-generated ID identifying this subscriber to Signal's
        /// services. Like a `donationSubscriberId` (see: `DonationSubscriptionManager`),
        /// this value is not associated with a user's account.
        ///
        /// - Note
        /// This value may have been generated by this client, or may have been
        /// generated by a former primary device for this account and later
        /// restored onto this device (e.g., via Storage Service or a backup).
        public let subscriberId: Data

        /// See doc on `IAPSubscriptionId`.
        public let iapSubscriptionId: IAPSubscriptionId

        fileprivate func matches(storeKitTransaction: Transaction) -> Bool {
            switch iapSubscriptionId {
            case .originalTransactionId(let originalTransactionId):
                return storeKitTransaction.originalID == originalTransactionId
            case .purchaseToken:
                return false
            }
        }
    }

    /// Describes the result of initiating a StoreKit purchase.
    public enum PurchaseResult {
        /// Purchase was successful. Contains the result of the purchase's
        /// redemption with Signal servers.
        ///
        /// - Note
        /// Success also covers if the user attempted to purchase this
        /// subscription, but was already subscribed.
        case success

        /// Purchase is pending external action, such as approval when "Ask to
        /// Buy" is enabled.
        case pending

        /// The user cancelled the purchase.
        case userCancelled
    }
}

// MARK: -

final class BackupSubscriptionManagerImpl: BackupSubscriptionManager {
    private enum Constants {
        /// This value corresponds to our IAP config set up in App Store
        /// Connect, and must not change!
        static let paidTierBackupsProductId = "backups.mediatier"
    }

    private let logger = PrefixedLogger(prefix: "[MessageBackup][Sub]")

    private let dateProvider: DateProvider
    private let db: any DB
    private let networkManager: NetworkManager
    private let receiptCredentialRedemptionJobQueue: BackupReceiptCredentialRedemptionJobQueue
    private let storageServiceManager: StorageServiceManager
    private let store: Store
    private let tsAccountManager: TSAccountManager

    init(
        dateProvider: @escaping DateProvider,
        db: any DB,
        networkManager: NetworkManager,
        receiptCredentialRedemptionJobQueue: BackupReceiptCredentialRedemptionJobQueue,
        storageServiceManager: StorageServiceManager,
        tsAccountManager: TSAccountManager
    ) {
        self.dateProvider = dateProvider
        self.db = db
        self.networkManager = networkManager
        self.receiptCredentialRedemptionJobQueue = receiptCredentialRedemptionJobQueue
        self.storageServiceManager = storageServiceManager
        self.store = Store()
        self.tsAccountManager = tsAccountManager

        listenForTransactionUpdates()
    }

    /// Returns the `Transaction` that most recently entitled us to the StoreKit
    /// "paid tier" subscription, or `nil` if we are not entitled to it.
    ///
    /// For example, if we originally purchased a subscription in transaction T,
    /// then renewed it twice in transactions T+1 (now expired) and T+2
    /// (currently valid), this method will return transaction T+2.
    private func latestEntitlingTransaction() async -> Transaction? {
        guard let latestEntitlingTransactionResult = await Transaction.currentEntitlement(
            for: Constants.paidTierBackupsProductId
        ) else {
            return nil
        }

        guard let latestEntitlingTransaction = try? latestEntitlingTransactionResult.payloadValue else {
            owsFailDebug(
                "Latest entitlement transaction was unverified!",
                logger: logger
            )
            return nil
        }

        return latestEntitlingTransaction
    }

    /// `Transaction.updates` is how the app is informed by StoreKit about
    /// transactions other than ones we completed inline via `.purchase()`. This
    /// covers scenarios like renewals and "Ask to Buy" where a transaction may
    /// occur asynchronously; we'll learn about those transactions here.
    ///
    /// If we learn about a transaction here that entitles us to a subscription
    /// we'll attempt a redemption. We don't need to be more precise than that,
    /// since we already regularly check if we need to perform a redemption and
    /// track relevant state on our own.
    private func listenForTransactionUpdates() {
        Task.detached { [weak self] in
            for await transactionResult in Transaction.updates {
                /// Guard on `self` in here, since we're in an async stream.
                guard let self else { return }

                guard let transaction = try? transactionResult.payloadValue else {
                    owsFailDebug(
                        "Transaction from update was unverified!",
                        logger: logger
                    )
                    continue
                }

                /// All transactions should be finished eventually, so let's
                /// make sure we do so.
                await transaction.finish()

                if
                    let latestEntitlingTransaction = await latestEntitlingTransaction(),
                    latestEntitlingTransaction.id == transaction.id
                {
                    logger.info("Transaction update is for latest entitling transaction; attempting subscription redemption.")

                    do {
                        /// This transaction entitles us to a subscription, so
                        /// let's attempt to do so.
                        try await redeemSubscriptionIfNecessary()
                    } catch {
                        owsFailDebug(
                            "Failed to redeem subscription: \(error)",
                            logger: logger
                        )
                    }
                } else {
                    logger.info("Transaction update is not for latest entitling subscription.")
                }
            }
        }
    }

    // MARK: -

    func getIAPSubscriberData(tx: any DBReadTransaction) -> IAPSubscriberData? {
        store.getIAPSubscriberData(tx: tx)
    }

    func restoreIAPSubscriberData(_ iapSubscriberData: IAPSubscriberData, tx: any DBWriteTransaction) {
        store.setIAPSubscriberData(iapSubscriberData, tx: tx)
    }

    // MARK: - Purchase new subscription

    func purchaseNewSubscription() async throws -> PurchaseResult {
        guard let paidTierProduct = try await Product.products(for: [Constants.paidTierBackupsProductId]).first else {
            throw OWSAssertionError(
                "Failed to get paid tier subscription product from StoreKit!",
                logger: logger
            )
        }

        switch try await paidTierProduct.purchase() {
        case .success(let purchaseResult):
            switch purchaseResult {
            case .verified:
                try await redeemSubscriptionIfNecessary()
                return .success
            case .unverified:
                throw OWSAssertionError(
                    "Unverified successful purchase result!",
                    logger: logger
                )
            }
        case .userCancelled:
            logger.info("User cancelled subscription purchase.")
            return .userCancelled
        case .pending:
            logger.warn("Subscription purchase is pending; expect redemption if it is approved.")
            return .pending
        @unknown default:
            throw OWSAssertionError(
                "Unknown purchase result!",
                logger: logger
            )
        }
    }

    // MARK: - Redeem subscription

    /// Serializes multiple attempts to redeem a subscription, so they don't
    /// race. Specifically, if a caller attempts to redeem a subscription while
    /// a previous caller's attempt is in progress, the latter caller will wait
    /// on the previous caller.
    ///
    /// `_redeemSubscriptionIfNecessary()` uses persisted state, so latter
    /// callers may be able to short-circuit based on state persisted by an
    /// earlier caller.
    private let redemptionAttemptSerializer = SerialTaskQueue()

    func redeemSubscriptionIfNecessary() async throws {
        return try await redemptionAttemptSerializer.enqueue {
            try await self._redeemSubscriptionIfNecessary()
        }.value
    }

    private func _redeemSubscriptionIfNecessary() async throws {
        /// Wait on any in-progress restores, since there's a chance we're
        /// restoring subscriber data.
        try? await storageServiceManager.waitForPendingRestores().awaitable()

        let persistedIAPSubscriberData: IAPSubscriberData? = db.read { tx in
            return store.getIAPSubscriberData(tx: tx)
        }

        let localEntitlingTransaction = await latestEntitlingTransaction()

        if
            let localEntitlingTransaction,
            let persistedIAPSubscriberData
        {
            if persistedIAPSubscriberData.matches(storeKitTransaction: localEntitlingTransaction) {
                /// We have an active local subscription that matches our persisted
                /// identifiers. That's the simplest happy-path! Great.
            } else {
                /// We have an active local subscription, but it doesn't match our
                /// persisted identifers. That must mean we initiated a subscription
                /// on another device (either with a different App Store account, or
                /// even on  an Android) and restored it here, and also have
                /// subscribed with our local App Store account.
                ///
                /// As a rule we prefer to rely on the local subscription, so we'll
                /// "claim" it by generating and registering identifiers for the
                /// local subscription!
                try await registerNewSubscriberId(
                    originalTransactionId: localEntitlingTransaction.originalID
                )
            }
        } else if let localEntitlingTransaction {
            /// We have a local subscription, but don't yet have any persisted
            /// identifiers. Generate and register them now!
            try await registerNewSubscriberId(
                originalTransactionId: localEntitlingTransaction.originalID
            )
        } else if persistedIAPSubscriberData != nil {
            /// We're don't have an active local subscription, but we do have
            /// identifiers for a subscription. The subscription may be from
            /// this device but since expired, or we may have restored the
            /// subscription from another device where we initiated the IAP
            /// subscription. Regardless, we'll move forward with the
            /// subscription identifiers in case they're still valid!
            logger.warn("Have persisted backup subscription IDs, but no local active subscription...")
        } else {
            /// We don't have an active local subscription, nor do we have
            /// subscription IDs for some other subscription. Nothing to do!
            return
        }

        let subscriptionRedemptionNecessaryChecker = SubscriptionRedemptionNecessityChecker<
            BackupReceiptCredentialRedemptionJobRecord
        >(
            checkerStore: store,
            dateProvider: dateProvider,
            db: db,
            logger: logger,
            networkManager: networkManager,
            tsAccountManager: tsAccountManager
        )

        try await subscriptionRedemptionNecessaryChecker.redeemSubscriptionIfNecessary(
            enqueueRedemptionJobBlock: { subscriberId, _, tx -> BackupReceiptCredentialRedemptionJobRecord in
                return receiptCredentialRedemptionJobQueue.saveBackupRedemptionJob(
                    subscriberId: subscriberId,
                    tx: tx
                )
            },
            startRedemptionJobBlock: { jobRecord async throws in
                try await receiptCredentialRedemptionJobQueue.runBackupRedemptionJob(jobRecord: jobRecord)
            }
        )
    }

    /// Generate a new subscriber ID, and register it with the server to be
    /// associated with the given StoreKit "original transaction ID" for a
    /// subscription. Persists and returns the new subscriber ID.
    private func registerNewSubscriberId(
        originalTransactionId: UInt64
    ) async throws {
        logger.info("Generating and registering new Backups subscriber ID!")

        let newSubscriberId: Data = Randomness.generateRandomBytes(32)

        /// First, we tell the server (unauthenticated) that a new subscriber ID
        /// exists. At this point, it won't be associated with anything.
        let registerSubscriberIdResponse = try await networkManager.makePromise(
            request: .registerSubscriberId(subscriberId: newSubscriberId)
        ).awaitable()

        guard registerSubscriberIdResponse.responseStatusCode == 200 else {
            throw OWSAssertionError(
                "Unexpected status code registering new Backup subscriber ID! \(registerSubscriberIdResponse.responseStatusCode)",
                logger: logger
            )
        }

        /// Next, we tell the server (unauthenticated) to associate the
        /// subscriber ID with the "original transaction ID" of an IAP.
        ///
        /// Importantly, this request is safe to make repeatedly, with any
        /// combination of `subscriberId` and `originalTransactionId`.
        let associateIdsResponse = try await networkManager.makePromise(
            request: .associateSubscriberId(
                newSubscriberId,
                withOriginalTransactionId: originalTransactionId
            )
        ).awaitable()

        guard associateIdsResponse.responseStatusCode == 200 else {
            throw OWSAssertionError(
                "Unexpected status code associating new Backup subscriber ID with originalTransactionId! \(associateIdsResponse.responseStatusCode)",
                logger: logger
            )
        }

        /// Our subscription is now set up on the service, and we should record
        /// it locally!
        await db.awaitableWrite { tx in
            let newSubscriberData = IAPSubscriberData(
                subscriberId: newSubscriberId,
                iapSubscriptionId: .originalTransactionId(originalTransactionId)
            )

            store.setIAPSubscriberData(newSubscriberData, tx: tx)
        }

        /// We store the subscriber data in Storage Service, so let's kick off
        /// that backup now.
        storageServiceManager.recordPendingLocalAccountUpdates()
    }

    // MARK: - Persistence

    private struct Store: SubscriptionRedemptionNecessityCheckerStore {
        private enum Keys {
            /// - SeeAlso ``BackupSubscription/IAPSubscriberData/subscriberId``
            static let subscriberId = "subscriberId"

            /// - SeeAlso ``BackupSubscription/IAPSubscriberData/subscriptionId``
            static let originalTransactionId = "originalTransactionId"

            /// - SeeAlso ``BackupSubscription/IAPSubscriberData/subscriptionId``
            static let purchaseToken = "purchaseToken"

            /// The renewal date of the last subscription period for which we
            /// affirmatively redeemed the subscription.
            ///
            /// Used by `SubscriptionRedemptionNecessityCheckerStore`.
            static let lastSubscriptionRenewalDate = "lastSubscriptionRenewalDate"

            /// The last time we checked if redemption is necessary.
            ///
            /// Used by `SubscriptionRedemptionNecessityCheckerStore`.
            static let lastRedemptionNecessaryCheck = "lastRedemptionNecessaryCheck"
        }

        private let kvStore: KeyValueStore

        init() {
            self.kvStore = KeyValueStore(collection: "BackupSubscriptionManagerImpl")
        }

        // MARK: -

        func getIAPSubscriberData(tx: DBReadTransaction) -> IAPSubscriberData? {
            guard let subscriberId = kvStore.getData(Keys.subscriberId, transaction: tx) else {
                return nil
            }

            if let originalTransactionId = kvStore.getUInt64(Keys.originalTransactionId, transaction: tx) {
                return IAPSubscriberData(
                    subscriberId: subscriberId,
                    iapSubscriptionId: .originalTransactionId(originalTransactionId)
                )
            } else if let purchaseToken = kvStore.getString(Keys.purchaseToken, transaction: tx) {
                return IAPSubscriberData(
                    subscriberId: subscriberId,
                    iapSubscriptionId: .purchaseToken(purchaseToken)
                )
            }

            owsFailDebug("Had subscriber ID, but missing IAP subscription ID!")
            return nil
        }

        func setIAPSubscriberData(_ iapSubscriberData: IAPSubscriberData, tx: DBWriteTransaction) {
            kvStore.setData(iapSubscriberData.subscriberId, key: Keys.subscriberId, transaction: tx)

            switch iapSubscriberData.iapSubscriptionId {
            case .originalTransactionId(let originalTransactionId):
                kvStore.removeValue(forKey: Keys.purchaseToken, transaction: tx)
                kvStore.setUInt64(originalTransactionId, key: Keys.originalTransactionId, transaction: tx)
            case .purchaseToken(let purchaseToken):
                kvStore.removeValue(forKey: Keys.originalTransactionId, transaction: tx)
                kvStore.setString(purchaseToken, key: Keys.purchaseToken, transaction: tx)
            }
        }

        // MARK: - SubscriptionRedemptionNecessityCheckerStore

        func subscriberId(tx: any DBReadTransaction) -> Data? {
            return getIAPSubscriberData(tx: tx)?.subscriberId
        }

        func getLastRedemptionNecessaryCheck(tx: any DBReadTransaction) -> Date? {
            return kvStore.getDate(Keys.lastRedemptionNecessaryCheck, transaction: tx)
        }

        func setLastRedemptionNecessaryCheck(_ now: Date, tx: any DBWriteTransaction) {
            kvStore.setDate(now, key: Keys.lastRedemptionNecessaryCheck, transaction: tx)
        }

        func getLastSubscriptionRenewalDate(tx: DBReadTransaction) -> Date? {
            return kvStore.getDate(Keys.lastSubscriptionRenewalDate, transaction: tx)
        }

        func setLastSubscriptionRenewalDate(_ renewalDate: Date, tx: DBWriteTransaction) {
            kvStore.setDate(renewalDate, key: Keys.lastSubscriptionRenewalDate, transaction: tx)
        }
    }
}

// MARK: -

private extension TSRequest {
    static func registerSubscriberId(subscriberId: Data) -> TSRequest {
        return OWSRequestFactory.setSubscriberID(subscriberId)
    }

    static func associateSubscriberId(
        _ subscriberId: Data,
        withOriginalTransactionId originalTransactionId: UInt64
    ) -> TSRequest {
        let request = TSRequest(
            url: URL(string: "v1/subscription/\(subscriberId.asBase64Url)/appstore/\(originalTransactionId)")!,
            method: "POST",
            parameters: nil
        )
        request.shouldHaveAuthorizationHeaders = false
        request.applyRedactionStrategy(.redactURLForSuccessResponses())
        return request
    }
}
