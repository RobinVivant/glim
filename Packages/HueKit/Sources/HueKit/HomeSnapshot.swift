import Foundation

/// Everything the app knows about the home at one moment. A value type: the
/// store mutates one copy, widgets and intents read a cached one.
public struct HomeSnapshot: Sendable, Equatable {
    public private(set) var lights: [String: Light] = [:]
    public private(set) var groupedLights: [String: GroupedLight] = [:]
    public private(set) var scenes: [String: LightScene] = [:]
    /// Rooms first, then zones, each by name.
    public private(set) var groups: [LightGroup] = []
    /// The grouped light that addresses every light on the bridge.
    public private(set) var homeGroupedLightID: String?

    private var raw: [String: JSONValue] = [:]
    private var scenesByGroup: [String: [LightScene]] = [:]
    private var unreachableDevices: Set<String> = []

    static let keptTypes: Set<String> = [
        "light", "grouped_light", "room", "zone", "device", "scene", "bridge_home", "zigbee_connectivity",
    ]

    public init() {}

    public init(resources: [JSONValue], preserving heldIDs: Set<String> = [], from previous: HomeSnapshot? = nil) {
        for resource in resources {
            guard let id = resource["id"]?.string, let type = resource["type"]?.string,
                HomeSnapshot.keptTypes.contains(type)
            else { continue }
            raw[id] = resource
        }
        if let previous {
            for id in heldIDs where raw[id] != nil {
                if let kept = previous.raw[id] { raw[id] = kept }
            }
        }
        for (id, resource) in raw { indexLeaf(id: id, resource: resource) }
        rebuildStructure()
    }

    /// The resources in the bridge's own JSON form, for caching.
    public var resources: [JSONValue] { Array(raw.values) }
    public var isEmpty: Bool { raw.isEmpty }

    // MARK: Reading

    public func group(_ id: String) -> LightGroup? { groups.first { $0.id == id } }

    public func lights(in group: LightGroup) -> [Light] {
        group.lightIDs.compactMap { lights[$0] }
    }

    public func scenes(in group: LightGroup) -> [LightScene] { scenesByGroup[group.id] ?? [] }

    public func activeScene(in group: LightGroup) -> LightScene? { scenes(in: group).first(where: \.isActive) }

    public func isReachable(_ light: Light) -> Bool { !unreachableDevices.contains(light.deviceID) }

    public func mirekRange(for group: LightGroup) -> ClosedRange<Int>? {
        let ranges = lights(in: group).compactMap(\.mirekRange)
        guard let first = ranges.first else { return nil }
        let low = ranges.map(\.lowerBound).max() ?? first.lowerBound
        let high = ranges.map(\.upperBound).min() ?? first.upperBound
        if low <= high { return low...high }
        let unionLow = ranges.map(\.lowerBound).min() ?? 153
        let unionHigh = ranges.map(\.upperBound).max() ?? 500
        return unionLow...unionHigh
    }

    public func clampedMirek(_ mirek: Int, for light: Light) -> Int {
        guard let range = light.mirekRange else { return mirek }
        return min(max(mirek, range.lowerBound), range.upperBound)
    }

    public func clampedMirek(_ mirek: Int, for group: LightGroup) -> Int {
        let range = mirekRange(for: group) ?? 153...500
        return min(max(mirek, range.lowerBound), range.upperBound)
    }

    public func relatedHoldIDs(for group: LightGroup) -> [String] {
        let targetLights = Set(group.lightIDs)
        var ids = targetLights
        ids.insert(group.groupedLightID)
        if let homeGroupedLightID { ids.insert(homeGroupedLightID) }
        for other in groups where other.id == group.id || !targetLights.isDisjoint(with: other.lightIDs) {
            ids.insert(other.groupedLightID)
            for scene in scenes(in: other) { ids.insert(scene.id) }
        }
        return Array(ids)
    }

    public func relatedHoldIDs(forLight lightID: String) -> [String] {
        var ids: Set<String> = [lightID]
        if let homeGroupedLightID { ids.insert(homeGroupedLightID) }
        for group in groups where group.lightIDs.contains(lightID) {
            ids.insert(group.groupedLightID)
            for scene in scenes(in: group) { ids.insert(scene.id) }
        }
        return Array(ids)
    }

    public func state(of group: LightGroup) -> GroupState {
        let members = lights(in: group)
        let lit = members.filter(\.isOn)
        let grouped = groupedLights[group.groupedLightID]
        let average = lit.isEmpty ? 0 : lit.reduce(0) { $0 + ($1.brightness ?? 100) } / Double(lit.count)
        let isOn = grouped?.isOn ?? !lit.isEmpty
        return GroupState(
            isOn: isOn,
            brightness: isOn ? (grouped?.brightness ?? average) : 0,
            tint: ColorMath.average(lit.map(\.displayColor)),
            lightsOn: lit.count,
            lightCount: members.count,
            isDimmable: members.contains { $0.brightness != nil },
            isReachable: members.isEmpty || members.contains(where: isReachable)
        )
    }

    public var anyLightOn: Bool {
        if let id = homeGroupedLightID, let home = groupedLights[id] { return home.isOn }
        return lights.values.contains(where: \.isOn)
    }

    public var anyReachableLightOn: Bool {
        lights.values.contains { $0.isOn && isReachable($0) }
    }

    // MARK: Changes from the bridge

    public mutating func apply(_ events: [HueEvent]) {
        for event in events {
            for resource in event.resources {
                guard let id = resource["id"]?.string else { continue }
                switch event.kind {
                case .update:
                    merge(id: id, patch: resource)
                case .add:
                    guard let type = resource["type"]?.string, HomeSnapshot.keptTypes.contains(type) else { continue }
                    raw[id] = resource
                    reindex(id: id)
                case .delete:
                    remove(id: id)
                }
            }
        }
    }

    /// Merges a partial resource into a known one. Unknown ids are ignored.
    public mutating func merge(id: String, patch: JSONValue) {
        guard let existing = raw[id] else { return }
        raw[id] = existing.merging(patch)
        reindex(id: id)
    }

    // MARK: Optimistic local changes

    public mutating func setGroupLocally(_ group: LightGroup, on: Bool) {
        for id in group.lightIDs { merge(id: id, patch: ["on": ["on": .bool(on)]]) }
        settleGroupedLights()
    }

    public mutating func setGroupLocally(_ group: LightGroup, brightness: Double) {
        for id in group.lightIDs {
            let dimmable = lights[id]?.brightness != nil
            merge(id: id, patch: dimmable ? ["on": ["on": true], "dimming": ["brightness": .number(brightness)]] : ["on": ["on": true]])
        }
        settleGroupedLights()
    }

    public mutating func setGroupLocally(_ group: LightGroup, mirek: Int) {
        let clamped = clampedMirek(mirek, for: group)
        for id in group.lightIDs {
            if let light = lights[id], light.mirekRange != nil {
                let value = clampedMirek(clamped, for: light)
                merge(
                    id: id,
                    patch: HomeSnapshot.asLightReports([
                        "on": ["on": true],
                        "color_temperature": ["mirek": .number(Double(value))],
                    ]))
            } else {
                merge(id: id, patch: ["on": ["on": true]])
            }
        }
        settleGroupedLights()
    }

    public mutating func setGroupLocally(_ group: LightGroup, color: XY) {
        let patch: JSONValue = [
            "on": ["on": true],
            "color": ["xy": ["x": .number(color.x), "y": .number(color.y)]],
        ]
        for id in group.lightIDs {
            if lights[id]?.xy != nil {
                merge(id: id, patch: HomeSnapshot.asLightReports(patch))
            } else {
                merge(id: id, patch: ["on": ["on": true]])
            }
        }
        settleGroupedLights()
    }

    public mutating func setLightLocally(id: String, patch: JSONValue) {
        merge(id: id, patch: HomeSnapshot.asLightReports(patch))
        settleGroupedLights()
    }

    /// A light told to show a color stops reporting a white point; mirror that
    /// so the light draws in its new color before the bridge confirms.
    private static func asLightReports(_ command: JSONValue) -> JSONValue {
        if command["color"] != nil, command["color_temperature"] == nil {
            return command.merging(["color_temperature": ["mirek": .null, "mirek_valid": false]])
        }
        if command["color_temperature"]?["mirek"]?.int != nil {
            return command.merging(["color_temperature": ["mirek_valid": true]])
        }
        return command
    }

    /// Shows a scene as recalled: its lights take the scene's values at once.
    public mutating func recallLocally(sceneID: String) {
        guard let scene = scenes[sceneID], let resource = raw[sceneID] else { return }
        for other in scenesByGroup[scene.groupID] ?? [] where other.id != sceneID && other.isActive {
            merge(id: other.id, patch: ["status": ["active": "inactive"]])
        }
        merge(id: sceneID, patch: ["status": ["active": "static"]])
        for entry in resource["actions"]?.array ?? [] {
            guard let target = entry["target"]?["rid"]?.string, let action = entry["action"] else { continue }
            merge(id: target, patch: HomeSnapshot.asLightReports(action))
        }
        settleGroupedLights()
    }

    public mutating func setAllLocally(on: Bool) {
        for id in lights.keys { merge(id: id, patch: ["on": ["on": .bool(on)]]) }
        settleGroupedLights()
    }

    /// Recomputes every grouped light from its members, as the bridge does: on when any
    /// light is on, at the average brightness of the lights that are on. A light keeps
    /// its brightness while off, so a room switched on shows its real level at once.
    private mutating func settleGroupedLights() {
        func settle(_ groupedLightID: String, members: [Light]) {
            let lit = members.filter(\.isOn)
            var patch: JSONValue = ["on": ["on": .bool(!lit.isEmpty)]]
            let levels = lit.compactMap(\.brightness)
            if !levels.isEmpty {
                patch = patch.merging(["dimming": ["brightness": .number(levels.reduce(0, +) / Double(levels.count))]])
            }
            merge(id: groupedLightID, patch: patch)
        }
        for group in groups {
            let members = lights(in: group)
            settle(group.groupedLightID, members: members)
            if !members.contains(where: \.isOn) {
                for scene in scenesByGroup[group.id] ?? [] where scene.isActive {
                    merge(id: scene.id, patch: ["status": ["active": "inactive"]])
                }
            }
        }
        if let home = homeGroupedLightID { settle(home, members: Array(lights.values)) }
    }

    // MARK: Indexing

    private mutating func remove(id: String) {
        guard raw.removeValue(forKey: id) != nil else { return }
        lights[id] = nil
        groupedLights[id] = nil
        scenes[id] = nil
        rebuildStructure()
    }

    private mutating func reindex(id: String) {
        guard let resource = raw[id] else { return }
        indexLeaf(id: id, resource: resource)
        switch resource["type"]?.string {
        case "scene": rebuildScenes()
        case "light": break
        case "grouped_light":
            if groupedLights[id]?.ownerType == "bridge_home" { homeGroupedLightID = id }
        case "device":
            for (lightID, light) in lights where light.deviceID == id {
                if let lightResource = raw[lightID] { indexLeaf(id: lightID, resource: lightResource) }
            }
            rebuildStructure()
        default: rebuildStructure()
        }
    }

    private mutating func indexLeaf(id: String, resource: JSONValue) {
        switch resource["type"]?.string {
        case "light":
            guard var light = Light(json: resource) else { return }
            if light.name.isEmpty { light.name = raw[light.deviceID]?["metadata"]?["name"]?.string ?? "Light" }
            lights[id] = light
        case "grouped_light":
            groupedLights[id] = GroupedLight(json: resource)
        case "scene":
            scenes[id] = LightScene(json: resource)
        default:
            break
        }
    }

    private mutating func rebuildScenes() {
        scenesByGroup = Dictionary(grouping: scenes.values, by: \.groupID).mapValues { scenes in
            scenes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    private mutating func rebuildStructure() {
        var built: [LightGroup] = []
        var unreachable: Set<String> = []
        for (id, resource) in raw {
            let type = resource["type"]?.string
            if type == "zigbee_connectivity", resource["status"]?.string != "connected",
                let device = resource["owner"]?["rid"]?.string
            {
                unreachable.insert(device)
            }
            guard let kind = type.flatMap(LightGroup.Kind.init(rawValue:)),
                let groupedLightID = resource["services"]?.array?
                    .first(where: { $0["rtype"]?.string == "grouped_light" })?["rid"]?.string
            else { continue }

            var lightIDs: [String] = []
            for child in resource["children"]?.array ?? [] {
                guard let rid = child["rid"]?.string else { continue }
                if child["rtype"]?.string == "light" {
                    lightIDs.append(rid)
                } else {
                    for service in raw[rid]?["services"]?.array ?? [] where service["rtype"]?.string == "light" {
                        if let lightID = service["rid"]?.string { lightIDs.append(lightID) }
                    }
                }
            }
            lightIDs.sort {
                (lights[$0]?.name ?? "").localizedStandardCompare(lights[$1]?.name ?? "") == .orderedAscending
            }
            built.append(
                LightGroup(
                    id: id,
                    kind: kind,
                    name: resource["metadata"]?["name"]?.string ?? "",
                    groupedLightID: groupedLightID,
                    lightIDs: lightIDs
                )
            )
        }
        groups = built.sorted { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind == .room }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        unreachableDevices = unreachable
        homeGroupedLightID = groupedLights.values.first { $0.ownerType == "bridge_home" }?.id
        rebuildScenes()
    }
}
