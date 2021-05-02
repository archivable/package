import CloudKit
import Combine

public struct Cloud<C>: Clouder where C : Controller {
    public let archive = CurrentValueSubject<C.A, Never>(.new)
    public let save = PassthroughSubject<C.A, Never>()
    public let pull = PassthroughSubject<Void, Never>()
    public let queue = DispatchQueue(label: "", qos: .utility)
    private var subs = Set<AnyCancellable>()
    private let local = PassthroughSubject<C.A?, Never>()
    
    public init() {
        let container = CKContainer(identifier: C.container)
        let push = PassthroughSubject<Void, Never>()
        let store = PassthroughSubject<(C.A, Bool), Never>()
        let remote = PassthroughSubject<C.A?, Never>()
        let record = CurrentValueSubject<CKRecord.ID?, Never>(nil)
        let type = "Archive"
        let asset = "asset"
        
        save
            .receive(on: DispatchQueue.main)
            .subscribe(archive)
            .store(in: &subs)
        
        save
            .map {
                ($0, true)
            }
            .subscribe(store)
            .store(in: &subs)
        
        local
            .compactMap {
                $0
            }
            .merge(with: remote
                            .compactMap {
                                $0
                            }
                            .map {
                                ($0, $0.date)
                            }
                            .merge(with: save
                                            .map { _ -> (C.A?, Date) in
                                                (nil, .init())
                                            })
                            .removeDuplicates {
                                $0.1 >= $1.1
                            }
                            .compactMap {
                                $0.0
                            })
            .removeDuplicates {
                $0 >= $1
            }
            .receive(on: DispatchQueue.main)
            .subscribe(archive)
            .store(in: &subs)
        
        pull
            .merge(with: push)
            .combineLatest(record)
            .filter {
                $1 == nil
            }
            .map { _, _ in }
            .sink {
                container.accountStatus { status, _ in
                    if status == .available {
                        container.fetchUserRecordID { user, _ in
                            user.map {
                                record.send(.init(recordName: C.prefix + $0.recordName))
                            }
                        }
                    }
                }
            }
            .store(in: &subs)
        
        record
            .compactMap {
                $0
            }
            .combineLatest(pull)
            .map {
                ($0.0, Date())
            }
            .removeDuplicates {
                Calendar.current.dateComponents([.second], from: $0.1, to: $1.1).second! < 2
            }
            .map {
                $0.0
            }
            .sink {
                let operation = CKFetchRecordsOperation(recordIDs: [$0])
                operation.qualityOfService = .userInitiated
                operation.configuration.timeoutIntervalForRequest = 20
                operation.configuration.timeoutIntervalForResource = 20
                operation.fetchRecordsCompletionBlock = { records, _ in
                    remote.send(records?.values.first.flatMap {
                        ($0[asset] as? CKAsset).flatMap {
                            $0.fileURL.flatMap {
                                (try? Data(contentsOf: $0)).map {
                                    $0.prototype()
                                }
                            }
                        }
                    })
                }
                container.publicCloudDatabase.add(operation)
            }
            .store(in: &subs)
        
        record
            .compactMap {
                $0
            }
            .sink {
                let subscription = CKQuerySubscription(
                    recordType: type,
                    predicate: .init(format: "recordID = %@", $0),
                    options: [.firesOnRecordUpdate])
                let notification = CKSubscription.NotificationInfo(alertLocalizationKey: C.title)
                notification.shouldSendContentAvailable = true
                subscription.notificationInfo = notification
                container.publicCloudDatabase.save(subscription) { _, _ in }
            }
            .store(in: &subs)
        
        record
            .compactMap {
                $0
            }
            .combineLatest(push)
            .map { id, _ in
                id
            }
            .sink {
                let record = CKRecord(recordType: type, recordID: $0)
                record[asset] = CKAsset(fileURL: C.file)
                let operation = CKModifyRecordsOperation(recordsToSave: [record])
                operation.qualityOfService = .userInitiated
                operation.configuration.timeoutIntervalForRequest = 20
                operation.configuration.timeoutIntervalForResource = 20
                operation.savePolicy = .allKeys
                container.publicCloudDatabase.add(operation)
            }
            .store(in: &subs)
        
        local
            .merge(with: save
                            .map {
                                $0 as C.A?
                            })
            .combineLatest(remote
                            .compactMap {
                                $0
                            }
                            .removeDuplicates())
            .filter {
                $0.0 == nil ? true : $0.0! < $0.1
            }
            .map {
                ($1, false)
            }
            .subscribe(store)
            .store(in: &subs)
        
        remote
            .map {
                ($0, .init())
            }
            .combineLatest(local
                            .compactMap {
                                $0
                            }
                            .merge(with: save))
            .filter { (item: ((C.A?, Date),  C.A)) -> Bool in
                item.0.0 == nil ? true : item.0.0! < item.1
            }
            .map { (remote: (C.A?, Date), _: C.A) -> Date in
                remote.1
            }
            .removeDuplicates()
            .map { _ in }
            .subscribe(push)
            .store(in: &subs)
        
        store
            .debounce(for: .seconds(1), scheduler: queue)
            .removeDuplicates {
                $0.0 >= $1.0
            }
            .sink {
                do {
                    try $0.0.data.write(to: C.file, options: .atomic)
                    if $0.1 {
                        push.send()
                    }
                } catch { }
            }
            .store(in: &subs)
        
        local.send(try? Data(contentsOf: C.file)
                            .prototype())
    }
    
    public func receipt(completion: @escaping (Bool) -> Void) {
        var sub: AnyCancellable?
        sub = archive
            .dropFirst()
            .map { _ in }
            .timeout(.seconds(6), scheduler: queue)
            .sink { _ in
                sub?.cancel()
                completion(true)
            } receiveValue: {
                sub?.cancel()
                completion(false)
            }
        pull.send()
    }
}