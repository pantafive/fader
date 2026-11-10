import Foundation

struct InputReconnectPolicy {
    private struct Pending {
        let uid: String
        let deadline: Date
        var fallbackUID: String?
    }

    private static let reconnectWindow: TimeInterval = 1
    private var previousDevices: Set<String> = []
    private var previousDefaultUID: String?
    private var pending: Pending?

    mutating func refresh(devices: Set<String>, defaultUID: String?, now: Date) -> String? {
        defer {
            previousDevices = devices
            previousDefaultUID = defaultUID
        }

        if let waiting = pending {
            if now > waiting.deadline ||
                (waiting.fallbackUID != nil && defaultUID != nil &&
                    defaultUID != waiting.fallbackUID && defaultUID != waiting.uid) {
                pending = nil
            } else if devices.contains(waiting.uid) {
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
              previousDevices.contains(previousDefaultUID), !devices.contains(previousDefaultUID)
        else { return nil }

        pending = Pending(uid: previousDefaultUID, deadline: now.addingTimeInterval(Self.reconnectWindow),
                          fallbackUID: defaultUID == previousDefaultUID ? nil : defaultUID)
        return nil
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
