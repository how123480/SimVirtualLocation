//
//  LogEntry.swift
//  SimVirtualLocation
//
//  Created by Sergey Shirnin on 21.05.2024.
//

import Foundation

/// Log entry for UI display
struct LogEntry: Identifiable {

    let id: UUID
    let date: Date
    let level: LogLevel
    let message: String
    /// Log source (filename:line)
    let location: String

    init(id: UUID = UUID(), date: Date, level: LogLevel = .info, message: String, location: String = "") {
        self.id = id
        self.date = date
        self.level = level
        self.message = message
        self.location = location
    }
}
