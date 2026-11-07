import Foundation

/// How much space one APFS volume uses.
public struct APFSVolumeUsage: Sendable, Hashable {
    /// Volume name, for example `Macintosh HD - Data`.
    public let name: String
    /// APFS roles, for example `["Data"]`, `["System"]`, `["VM"]`. Empty for plain volumes.
    public let roles: [String]
    /// Bytes this volume uses inside the container.
    public let bytesUsed: Int64

    /// Creates a volume usage value.
    public init(name: String, roles: [String], bytesUsed: Int64) {
        self.name = name
        self.roles = roles
        self.bytesUsed = bytesUsed
    }
}

/// One APFS container from `diskutil apfs list -plist`.
struct APFSContainer: Sendable, Hashable {
    /// BSD name such as `disk3`.
    let reference: String
    let volumes: [APFSVolumeUsage]
}

/// Parses `diskutil apfs list -plist` and `diskutil info -plist /`.
enum APFSListParser {
    /// Reads every container and its volumes.
    ///
    /// Unknown keys are ignored. A volume without a name, or with no usable size, is skipped.
    /// - Throws: ``ProbeError/parse(_:)`` when the data is not a plist with a `Containers` array.
    static func parse(plist: Data) throws(ProbeError) -> [APFSContainer] {
        let root = try dictionary(from: plist)
        guard let rawContainers = root["Containers"] as? [[String: Any]] else {
            throw .parse("diskutil apfs list: no Containers array")
        }
        return rawContainers.compactMap { raw in
            guard let reference = raw["ContainerReference"] as? String else { return nil }
            let rawVolumes = raw["Volumes"] as? [[String: Any]] ?? []
            let volumes = rawVolumes.compactMap { volume -> APFSVolumeUsage? in
                guard
                    let name = volume["Name"] as? String,
                    let used = (volume["CapacityInUse"] as? NSNumber)?.int64Value
                else { return nil }
                return APFSVolumeUsage(name: name, roles: volume["Roles"] as? [String] ?? [], bytesUsed: used)
            }
            return APFSContainer(reference: reference, volumes: volumes)
        }
    }

    /// Reads `APFSContainerReference` from `diskutil info -plist /`.
    /// - Throws: ``ProbeError/parse(_:)`` when the data is not a plist or the key is missing.
    static func containerReference(infoPlist: Data) throws(ProbeError) -> String {
        let root = try dictionary(from: infoPlist)
        guard let reference = root["APFSContainerReference"] as? String, !reference.isEmpty else {
            throw .parse("diskutil info: no APFSContainerReference")
        }
        return reference
    }

    /// Picks the container that holds the startup volume.
    ///
    /// Uses the reference from `diskutil info` when given. Otherwise falls back to the only
    /// container that has a `Data` volume. Returns `nil` when the choice is not clear.
    static func startupContainer(in containers: [APFSContainer], reference: String?) -> APFSContainer? {
        if let reference {
            return containers.first { $0.reference == reference }
        }
        let withData = containers.filter { container in
            container.volumes.contains { $0.roles.contains("Data") }
        }
        return withData.count == 1 ? withData.first : nil
    }

    private static func dictionary(from data: Data) throws(ProbeError) -> [String: Any] {
        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        } catch {
            throw .parse("not a property list")
        }
        guard let dictionary = object as? [String: Any] else {
            throw .parse("property list root is not a dictionary")
        }
        return dictionary
    }
}
