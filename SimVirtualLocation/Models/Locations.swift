//
//  Locations.swift
//  SimVirtualLocation
//
//  Created by Sergey Shirnin on 19.11.2023.
//

import Foundation
import CoreLocation
import SwiftUI
import UniformTypeIdentifiers

struct LocationsFileDocument: FileDocument {

    static let readableContentTypes: [UTType] = [.json]

    let locations: [Location]

    init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents {
            self.locations = try JSONDecoder().decode([Location].self, from: data)
        } else {
            self.locations = []
        }
    }

    init(locations: [Location]) {
        self.locations = locations
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = try JSONEncoder().encode(locations)
        return FileWrapper(regularFileWithContents: data)
    }
}

struct Location: Codable, Identifiable {
    // Stable per-record identity. Required so duplicate coordinates are
    // independently identifiable in the UI and individually deletable.
    var id: UUID = UUID()

    let name: String
    let latitude: Double
    let longitude: Double
    /// IDs of LocationLabel records this location belongs to. Empty == untagged.
    var labelIDs: [UUID] = []

    enum CodingKeys: String, CodingKey {
        case id, name, latitude, longitude, labelIDs
    }

    init(name: String, latitude: Double, longitude: Double, labelIDs: [UUID] = []) {
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.labelIDs = labelIDs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Older saved data has no `id` / `labelIDs` field — synthesize.
        self.id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        self.name = try c.decode(String.self, forKey: .name)
        self.latitude = try c.decode(Double.self, forKey: .latitude)
        self.longitude = try c.decode(Double.self, forKey: .longitude)
        self.labelIDs = (try? c.decode([UUID].self, forKey: .labelIDs)) ?? []
    }
}

/// User-defined tag that groups saved locations. Many-to-many: a Location
/// holds a list of LocationLabel IDs, and a label is "applied" wherever its
/// ID appears in that list.
struct LocationLabel: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String

    init(name: String) {
        self.name = name
    }

    enum CodingKeys: String, CodingKey {
        case id, name
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        self.name = try c.decode(String.self, forKey: .name)
    }
}
