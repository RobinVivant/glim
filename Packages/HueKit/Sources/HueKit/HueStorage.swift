import Foundation

/// The files the app, its widgets and its intents share: the pairing and the
/// last known home state.
public struct HueStorage: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// Storage in the App Group container, so extensions see the same files.
    public static func appGroup(_ identifier: String) -> HueStorage {
        let base =
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
            ?? URL.applicationSupportDirectory
        return HueStorage(directory: base.appending(path: "Glim", directoryHint: .isDirectory))
    }

    private var credentialsURL: URL { directory.appending(path: "bridge.json") }
    private var snapshotURL: URL { directory.appending(path: "home.json") }
    private var lastWriteURL: URL { directory.appending(path: "last-write") }

    public func loadCredentials() -> BridgeCredentials? {
        guard let data = try? Data(contentsOf: credentialsURL) else { return nil }
        return try? JSONDecoder().decode(BridgeCredentials.self, from: data)
    }

    public func saveCredentials(_ credentials: BridgeCredentials) throws {
        try write(JSONEncoder().encode(credentials), to: credentialsURL)
    }

    public func deleteSnapshot() {
        try? FileManager.default.removeItem(at: snapshotURL)
        try? FileManager.default.removeItem(at: lastWriteURL)
    }

    public func deleteAll() {
        try? FileManager.default.removeItem(at: credentialsURL)
        deleteSnapshot()
    }

    public func loadSnapshot() -> HomeSnapshot? {
        guard let data = try? Data(contentsOf: snapshotURL), let resources = try? JSONValue(data: data).array else {
            return nil
        }
        return HomeSnapshot(resources: resources)
    }

    public func saveSnapshot(_ snapshot: HomeSnapshot) {
        guard let data = try? JSONValue.array(snapshot.resources).data() else { return }
        try? write(data, to: snapshotURL)
    }

    public func markRemoteWrite() {
        try? write(Data([1]), to: lastWriteURL)
    }

    public var secondsSinceRemoteWrite: TimeInterval? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: lastWriteURL.path(percentEncoded: false)),
            let modified = attributes[.modificationDate] as? Date
        else { return nil }
        return Date().timeIntervalSince(modified)
    }

    /// Readable after the first unlock, because Lock Screen controls run while the phone is locked.
    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
