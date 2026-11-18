import Foundation

public struct Light: Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var deviceID: String
    public var isOn: Bool
    /// 0...100, nil when the light cannot dim.
    public var brightness: Double?
    /// Current white point, nil when the light is showing a color.
    public var mirek: Int?
    /// Present when the light supports white temperature.
    public var mirekRange: ClosedRange<Int>?
    /// Present when the light supports color.
    public var xy: XY?

    init?(json: JSONValue) {
        guard let id = json["id"]?.string else { return nil }
        self.id = id
        name = json["metadata"]?["name"]?.string ?? ""
        deviceID = json["owner"]?["rid"]?.string ?? ""
        isOn = json["on"]?["on"]?.bool ?? false
        brightness = json["dimming"]?["brightness"]?.double
        let temperature = json["color_temperature"]
        mirek = temperature?["mirek"]?.int
        if let low = temperature?["mirek_schema"]?["mirek_minimum"]?.int,
            let high = temperature?["mirek_schema"]?["mirek_maximum"]?.int, low <= high
        {
            mirekRange = low...high
        }
        if let x = json["color"]?["xy"]?["x"]?.double, let y = json["color"]?["xy"]?["y"]?.double {
            xy = XY(x: x, y: y)
        }
    }

    /// The color to draw this light with, ignoring brightness.
    public var displayColor: RGB {
        if let mirek, mirekRange != nil { return ColorMath.rgb(mirek: mirek) }
        if let xy { return ColorMath.rgb(xy) }
        return ColorMath.rgb(mirek: 366)
    }
}

public struct GroupedLight: Identifiable, Hashable, Sendable {
    public let id: String
    public var ownerID: String
    public var ownerType: String
    public var isOn: Bool
    public var brightness: Double?

    init?(json: JSONValue) {
        guard let id = json["id"]?.string else { return nil }
        self.id = id
        ownerID = json["owner"]?["rid"]?.string ?? ""
        ownerType = json["owner"]?["rtype"]?.string ?? ""
        isOn = json["on"]?["on"]?.bool ?? false
        brightness = json["dimming"]?["brightness"]?.double
    }
}

public struct LightScene: Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var groupID: String
    public var isActive: Bool
    /// A few representative colors of the scene, for drawing it.
    public var swatches: [RGB]

    init?(json: JSONValue) {
        guard let id = json["id"]?.string else { return nil }
        self.id = id
        name = json["metadata"]?["name"]?.string ?? ""
        groupID = json["group"]?["rid"]?.string ?? ""
        isActive = (json["status"]?["active"]?.string ?? "inactive") != "inactive"

        var colors: [RGB] = []
        for entry in json["actions"]?.array ?? [] {
            guard let action = entry["action"], action["on"]?["on"]?.bool != false else { continue }
            if let color = LightScene.color(in: action) { colors.append(color) }
        }
        if colors.isEmpty {
            for entry in json["palette"]?["color"]?.array ?? [] {
                if let color = LightScene.color(in: entry) { colors.append(color) }
            }
        }
        var distinct: [RGB] = []
        for color in colors where !distinct.contains(where: { $0.isClose(to: color) }) {
            distinct.append(color)
            if distinct.count == 3 { break }
        }
        swatches = distinct
    }

    private static func color(in json: JSONValue) -> RGB? {
        if let x = json["color"]?["xy"]?["x"]?.double, let y = json["color"]?["xy"]?["y"]?.double {
            return ColorMath.rgb(XY(x: x, y: y))
        }
        if let mirek = json["color_temperature"]?["mirek"]?.int {
            return ColorMath.rgb(mirek: mirek)
        }
        return nil
    }
}

extension RGB {
    func isClose(to other: RGB) -> Bool {
        abs(r - other.r) + abs(g - other.g) + abs(b - other.b) < 0.12
    }
}

/// A room or a zone: the unit the main screen shows a row for.
public struct LightGroup: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case room, zone }

    public let id: String
    public var kind: Kind
    public var name: String
    public var groupedLightID: String
    public var lightIDs: [String]
}

public struct GroupState: Hashable, Sendable {
    public var isOn: Bool
    /// 0...100.
    public var brightness: Double
    /// Average color of the lights that are on, nil when all are off.
    public var tint: RGB?
    public var lightsOn: Int
    public var lightCount: Int
}

public struct HueEvent: Sendable {
    public enum Kind: String, Sendable { case update, add, delete }

    public let kind: Kind
    public let resources: [JSONValue]

    /// Parses one `data:` payload of the bridge's event stream.
    public static func parse(_ data: Data) -> [HueEvent] {
        guard let containers = try? JSONValue(data: data).array else { return [] }
        return containers.compactMap { container in
            guard let kind = container["type"]?.string.flatMap(Kind.init(rawValue:)),
                let resources = container["data"]?.array
            else { return nil }
            return HueEvent(kind: kind, resources: resources)
        }
    }
}
