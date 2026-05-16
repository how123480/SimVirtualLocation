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

    enum CodingKeys: String, CodingKey {
        case id, name, latitude, longitude
    }

    init(name: String, latitude: Double, longitude: Double) {
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Older saved data has no `id` field — synthesize one.
        self.id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        self.name = try c.decode(String.self, forKey: .name)
        self.latitude = try c.decode(Double.self, forKey: .latitude)
        self.longitude = try c.decode(Double.self, forKey: .longitude)
    }
}
