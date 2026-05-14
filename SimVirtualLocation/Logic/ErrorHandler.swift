//
//  ErrorHandler.swift
//  SimVirtualLocation
//
//  Single funnel for application errors. Decides:
//    - Whether to write a log entry (always).
//    - Whether to wipe simulation state (AppError.requiresStateReset).
//    - Whether to surface an alert to the user (AppError.shouldShowAlert).
//

import Foundation

@MainActor
protocol ErrorHandlerHost: AnyObject {
    func resetAllState()
    func presentAlert(message: String)
}

@MainActor
final class ErrorHandler {

    // MARK: - Private Properties

    private weak var host: ErrorHandlerHost?
    private let logger = AppLogger.shared

    // MARK: - Init

    init(host: ErrorHandlerHost) {
        self.host = host
    }

    // MARK: - Public Methods

    func handle(_ error: Error, context: String = #function) {
        let appError = Self.normalize(error)
        logger.error("[\(context)] \(appError)")

        if appError.requiresStateReset {
            host?.resetAllState()
        }
        if appError.shouldShowAlert {
            host?.presentAlert(message: appError.userMessage)
        }
    }

    // MARK: - Private Methods

    private static func normalize(_ error: Error) -> AppError {
        if let appError = error as? AppError {
            return appError
        }
        return .processFailed(command: "unknown", stderr: error.localizedDescription)
    }
}
