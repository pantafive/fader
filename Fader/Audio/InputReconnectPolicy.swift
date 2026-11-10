import Foundation

struct InputReconnectPolicy {
    private struct Pending {
        let uid: String
        let deadline: Date
        var fallbackUID: String?
    }

    private static let reconnectWindow: TimeInterval = 10
    private var previousDevices: [String: UInt32] = [:]
    private var previousDefaultUID: String?
    private var pending: Pending?

    mutating func refresh(devices: [String: UInt32], defaultUID: String?, now: Date) -> String? {
        defer {
            previousDevices = devices
            previousDefaultUID = defaultUID
        }

        if let waiting = pending {
            if now > waiting.deadline ||
                (waiting.fallbackUID != nil && defaultUID != nil &&
                    defaultUID != waiting.fallbackUID && defaultUID != waiting.uid) {
                pending = nil
            } else if devices[waiting.uid] != nil {
                if defaultUID == waiting.uid {
                    pending = nil
                    return nil
                }
                return waiting.uid
            } else if waiting.fallbackUID == nil, defaultUID != waiting.uid {
                pending?.fallbackUID = defaultUID
            }
        }

        guard pending == nil, let previousDefaultUID,
              let previousID = previousDevices[previousDefaultUID],
              devices[previousDefaultUID] == nil ||
              (devices[previousDefaultUID] != previousID && defaultUID != previousDefaultUID)
        else { return nil }

        // A USB reset can finish within the monitor's coalescing interval.
        // Its UID survives but its HAL object ID changes.
        pending = Pending(uid: previousDefaultUID, deadline: now.addingTimeInterval(Self.reconnectWindow),
                          fallbackUID: defaultUID == previousDefaultUID ? nil : defaultUID)
        return devices[previousDefaultUID] == nil ? nil : previousDefaultUID
    }

    mutating func cancel() {
        pending = nil
    }

    mutating func didSwitch(to uid: String) {
        previousDefaultUID = uid
        if pending?.uid == uid {
            pending = nil
        } else {
            pending?.fallbackUID = uid
        }
    }
}
