//
//  Device.swift
//  SimVirtualLocation
//
//  Created by Sergey Shirnin on 21.02.2022.
//

import Foundation

struct Device: Hashable, Identifiable, Decodable {

    private enum CodingKeys: String, CodingKey {
        case id = "Identifier"
        case name = "DeviceName"
        case version = "ProductVersion"
        case connectionType = "ConnectionType"
    }

    let id: String
    let name: String
    let version: String
    let connectionType: String?

    var isUSB: Bool {
        guard let t = connectionType else { return true }  // unknown → keep (older pymobiledevice3)
        return t.uppercased() == "USB"
    }
}
