//
//  UsbmuxWatcher.swift
//  SimVirtualLocation
//

import Foundation
import Network

/// Subscribes to usbmuxd's device event stream (the `Listen` request over
/// /var/run/usbmuxd) and reports whenever the set of devices usbmuxd knows
/// about changes. Owns no device state — consumers re-query the list
/// themselves. Reconnects with backoff if the socket drops (e.g. usbmuxd
/// restart) and must never mutate app state or present alerts.
@MainActor
final class UsbmuxWatcher {

    // MARK: - Public Properties

    /// Fired on every Attached/Detached event, and once right after each
    /// successful (re)subscribe so a reconnect after missed events self-heals.
    var onDeviceListChanged: (() -> Void)?

    // MARK: - Private Properties

    private let logger = AppLogger.shared

    private var connection: NWConnection?

    /// Bumped on every start()/stop()/reconnect. Callbacks from a superseded
    /// connection compare against it and bail, so a cancelled socket can never
    /// double-schedule reconnects.
    private var generation = 0

    private var reconnectDelay: TimeInterval = Constants.initialReconnectDelay

    /// First transport failure logs at info, repeats at debug — the watcher
    /// retries forever and must not spam the log while usbmuxd is down.
    private var hasLoggedFailure = false

    private enum Constants {
        static let socketPath = "/var/run/usbmuxd"
        static let initialReconnectDelay: TimeInterval = 2
        static let maxReconnectDelay: TimeInterval = 30
        static let headerSize = 16
        static let protocolVersion: UInt32 = 1
        static let plistMessageType: UInt32 = 8
        static let maxFrameLength = 1_000_000
    }

    // MARK: - Public Methods

    func start() {
        generation += 1
        open(generation: generation)
    }

    func stop() {
        generation += 1
        connection?.cancel()
        connection = nil
    }

    // MARK: - Private Methods

    private func open(generation: Int) {
        let conn = NWConnection(to: .unix(path: Constants.socketPath), using: .tcp)
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                switch state {
                case .ready:
                    self.subscribe(on: conn, generation: generation)
                case .failed(let error):
                    self.scheduleReconnect(generation: generation, reason: "socket failed: \(error)")
                case .waiting(let error):
                    // .waiting never resolves for a missing/refused unix
                    // socket — treat it as a failure and back off.
                    self.scheduleReconnect(generation: generation, reason: "socket unavailable: \(error)")
                default:
                    break
                }
            }
        }
        conn.start(queue: .main)
    }

    private func subscribe(on conn: NWConnection, generation: Int) {
        let request: [String: Any] = [
            "MessageType": "Listen",
            "ClientVersionString": "SimVirtualLocation",
            "ProgName": "SimVirtualLocation",
        ]
        guard let payload = try? PropertyListSerialization.data(fromPropertyList: request, format: .xml, options: 0) else {
            logger.error("UsbmuxWatcher: failed to encode Listen request")
            return
        }
        var frame = Data(capacity: Constants.headerSize + payload.count)
        frame.appendLittleEndian(UInt32(Constants.headerSize + payload.count))
        frame.appendLittleEndian(Constants.protocolVersion)
        frame.appendLittleEndian(Constants.plistMessageType)
        frame.appendLittleEndian(UInt32(1))  // tag (unused: we never multiplex requests)
        frame.append(payload)
        conn.send(content: frame, completion: .contentProcessed { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                if error != nil {
                    self.scheduleReconnect(generation: generation, reason: "Listen send failed")
                    return
                }
                self.readMessage(on: conn, generation: generation, isSubscribeReply: true)
            }
        })
    }

    private func readMessage(on conn: NWConnection, generation: Int, isSubscribeReply: Bool) {
        conn.receive(minimumIncompleteLength: Constants.headerSize, maximumLength: Constants.headerSize) { [weak self] data, _, _, error in
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                guard error == nil, let data, data.count == Constants.headerSize else {
                    self.scheduleReconnect(generation: generation, reason: "header read failed")
                    return
                }
                let length = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }.littleEndian)
                let payloadLength = length - Constants.headerSize
                guard payloadLength > 0, payloadLength < Constants.maxFrameLength else {
                    self.scheduleReconnect(generation: generation, reason: "bad frame length \(length)")
                    return
                }
                self.readPayload(on: conn, generation: generation, length: payloadLength, isSubscribeReply: isSubscribeReply)
            }
        }
    }

    private func readPayload(on conn: NWConnection, generation: Int, length: Int, isSubscribeReply: Bool) {
        conn.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, _, error in
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                guard error == nil, let data, data.count == length else {
                    self.scheduleReconnect(generation: generation, reason: "payload read failed")
                    return
                }
                self.handleMessage(data, generation: generation, isSubscribeReply: isSubscribeReply)
                guard self.generation == generation else { return }  // handleMessage may have reconnected
                self.readMessage(on: conn, generation: generation, isSubscribeReply: false)
            }
        }
    }

    private func handleMessage(_ payload: Data, generation: Int, isSubscribeReply: Bool) {
        guard let plist = try? PropertyListSerialization.propertyList(from: payload, options: [], format: nil),
              let message = plist as? [String: Any] else {
            logger.debug("UsbmuxWatcher: dropping undecodable frame")
            return
        }
        let type = message["MessageType"] as? String ?? ""
        if isSubscribeReply {
            let number = message["Number"] as? Int ?? -1
            guard type == "Result", number == 0 else {
                scheduleReconnect(generation: generation, reason: "Listen rejected: \(type)/\(number)")
                return
            }
            logger.info("UsbmuxWatcher: subscribed to usbmuxd device events")
            reconnectDelay = Constants.initialReconnectDelay
            hasLoggedFailure = false
            onDeviceListChanged?()
            return
        }
        switch type {
        case "Attached", "Detached":
            logger.debug("UsbmuxWatcher: device event \(type)")
            onDeviceListChanged?()
        default:
            break
        }
    }

    private func scheduleReconnect(generation: Int, reason: String) {
        guard self.generation == generation else { return }
        connection?.cancel()
        connection = nil
        self.generation += 1
        let next = self.generation
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, Constants.maxReconnectDelay)
        if hasLoggedFailure {
            logger.debug("UsbmuxWatcher: \(reason); retrying in \(Int(delay))s")
        } else {
            logger.info("UsbmuxWatcher: \(reason); retrying in \(Int(delay))s")
            hasLoggedFailure = true
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, self.generation == next else { return }
            self.open(generation: next)
        }
    }
}

private extension Data {
    mutating func appendLittleEndian(_ value: UInt32) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}
