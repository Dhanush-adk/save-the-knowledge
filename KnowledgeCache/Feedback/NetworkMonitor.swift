//
//  NetworkMonitor.swift
//  KnowledgeCache
//
//  Observes network connectivity so we can flush pending feedback when the device comes online.
//

import Foundation
import Network

@MainActor
final class NetworkMonitor: ObservableObject {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.knowledgecache.networkmonitor")

    @Published private(set) var isConnected = false

    var onBecameConnected: (() -> Void)?

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            Task { @MainActor in
                let wasConnected = self?.isConnected ?? false
                self?.isConnected = connected
                if connected, !wasConnected {
                    self?.onBecameConnected?()
                }
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
