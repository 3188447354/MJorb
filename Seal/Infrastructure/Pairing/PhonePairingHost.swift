import Foundation
@preconcurrency import Minimuxer

/// The device-side Remote Pairing host used by iOS 27. It only owns the
/// ephemeral Bonjour advertisement and the host identity file; `PairingStore`
/// remains the sole authority for the credential used by signing and install.
@MainActor
final class PhonePairingHost: NSObject {
    enum Event: Equatable {
        case requestingLocalNetwork
        case waitingForSystemConfirmation
        case showingCode(String)
        case completed(URL)
        case failed(String)
    }

    private static let hostName = "Seal"
    // Apple presents this endpoint as a Mac-like Remote Pairing host.
    private static let hostModel = "Mac17,7"
    private static let altIRKKey = "seal.phonePairingHostAltIRK"
    private static let pairingFileName = "SealPhonePairingHost.mobiledevicepairing"

    private var service: NetService?
    private var activeRunID: UUID?
    private var eventHandler: ((Event) -> Void)?

    var isRunning: Bool { activeRunID != nil }

    func start(onEvent: @escaping (Event) -> Void) {
        guard activeRunID == nil else {
            onEvent(.failed("配对已在进行中。"))
            return
        }
        guard let outputURL = Self.hostPairingFileURL() else {
            onEvent(.failed("无法准备设备配对所需的本机文件。"))
            return
        }

        let runID = UUID()
        activeRunID = runID
        eventHandler = onEvent
        onEvent(.requestingLocalNetwork)

        let outputPath = outputURL.path
        let storedAltIRK = UserDefaults.standard.string(forKey: Self.altIRKKey) ?? ""
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let result = try Minimuxer.runPhonePairingHost(
                    name: Self.hostName,
                    model: Self.hostModel,
                    outputPath: outputPath,
                    hostAltIRKHex: storedAltIRK,
                    onReady: { advertisement in
                        DispatchQueue.main.async { [weak self] in
                            self?.advertise(advertisement, runID: runID)
                        }
                    },
                    onPIN: { code in
                        DispatchQueue.main.async { [weak self] in
                            self?.emit(.showingCode(code), for: runID)
                        }
                    }
                )
                UserDefaults.standard.set(result.hostAltIRKHex, forKey: Self.altIRKKey)
                try? CompleteFileProtector().protect(outputURL)
                DispatchQueue.main.async { [weak self] in
                    self?.finish(.completed(outputURL), runID: runID)
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.finish(.failed(error.localizedDescription), runID: runID)
                }
            }
        }
    }

    private func advertise(
        _ advertisement: Minimuxer.PhonePairingAdvertisement,
        runID: UUID
    ) {
        guard activeRunID == runID else { return }
        service?.stop()
        let service = NetService(
            domain: "",
            type: "_remotepairing-pairable-host._tcp.",
            name: advertisement.serviceIdentifier,
            port: Int32(advertisement.port)
        )
        let txt = advertisement.txtRecords.mapValues { Data($0.utf8) }
        service.setTXTRecord(NetService.data(fromTXTRecord: txt))
        service.publish()
        self.service = service
        emit(.waitingForSystemConfirmation, for: runID)
    }

    private func finish(_ event: Event, runID: UUID) {
        guard activeRunID == runID else { return }
        service?.stop()
        service = nil
        activeRunID = nil
        emit(event, for: runID)
        eventHandler = nil
    }

    private func emit(_ event: Event, for runID: UUID) {
        guard activeRunID == runID || isTerminal(event) else { return }
        eventHandler?(event)
    }

    private func isTerminal(_ event: Event) -> Bool {
        switch event {
        case .completed, .failed:
            return true
        case .requestingLocalNetwork, .waitingForSystemConfirmation, .showingCode:
            return false
        }
    }

    private static func hostPairingFileURL() -> URL? {
        guard let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        let directory = root.appending(path: "Seal", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try CompleteFileProtector().protect(directory)
            return directory.appending(path: pairingFileName, directoryHint: .notDirectory)
        } catch {
            return nil
        }
    }
}
