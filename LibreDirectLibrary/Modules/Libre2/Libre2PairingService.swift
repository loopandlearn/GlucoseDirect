//
//  SensorPairing.swift
//  LibreDirect
//
//  Created by Reimar Metzen on 06.07.21.
//

import Foundation
import Combine
import CoreNFC

typealias Libre2PairingHandler = (_ uuid: Data, _ patchInfo: Data, _ fram: Data, _ streamingEnabled: Bool) -> Void

struct Libre2Pairing {
    let uuid: Data
    let patchInfo: Data
    let fram: Data
    let streamingEnabled: Bool
}

@available(iOS 15.0, *)
class Libre2PairingService: NSObject, NFCTagReaderSessionDelegate {
    private var session: NFCTagReaderSession? = nil
    private var continuation: CheckedContinuation<Libre2Pairing?, Never>? = nil

    private let nfcQueue = DispatchQueue(label: "libre-direct.nfc-queue")
    private let accessQueue = DispatchQueue(label: "libre-direct.nfc-access-queue")

    private let unlockCode: UInt32 = 42

    func pairSensor() async -> Libre2Pairing? {
        return await withCheckedContinuation() { continuation in
            if NFCTagReaderSession.readingAvailable {
                self.continuation = continuation
                
                accessQueue.async {
                    self.session = NFCTagReaderSession(pollingOption: .iso15693, delegate: self, queue: self.nfcQueue)
                    self.session?.alertMessage = LocalizedString("Hold the top of your iPhone near the sensor to pair", comment: "")
                    self.session?.begin()
                }
            } else {
                continuation.resume(returning: nil)
            }
        }
    }

    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        Task {
            guard let firstTag = tags.first else {
                self.continuation?.resume(returning: nil)
                return
            }

            guard case .iso15693(let tag) = firstTag else {
                self.continuation?.resume(returning: nil)
                return
            }

            let blocks = 43
            let requestBlocks = 3

            let requests = Int(ceil(Double(blocks) / Double(requestBlocks)))
            let remainder = blocks % requestBlocks
            var dataArray = [Data](repeating: Data(), count: blocks)

            try await session.connect(to: firstTag)

            let patchInfo = try await tag.customCommand(requestFlags: .highDataRate, customCommandCode: 0xA1, customRequestParameters: Data())
            guard patchInfo.count >= 6 else { // patchInfo should have length 6, which sometimes is not the case, as there are occuring crashes in nfcCommand and Libre2BLEUtilities.streamingUnlockPayload
                return
            }

            let sensorUID = Data(tag.identifier.reversed()) // get sensorUID and patchInfo and send to delegate

            for i in 0 ..< requests {
                let requestFlags: NFCISO15693RequestFlag = [.highDataRate, .address]
                let blockRange = NSRange(UInt8(i * requestBlocks) ... UInt8(i * requestBlocks + (i == requests - 1 ? (remainder == 0 ? requestBlocks : remainder) : requestBlocks) - (requestBlocks > 1 ? 1 : 0)))

                let blockArray = try await tag.readMultipleBlocks(requestFlags: requestFlags, blockRange: blockRange)

                for j in 0 ..< blockArray.count {
                    dataArray[i * requestBlocks + j] = blockArray[j]
                }

                if i == requests - 1 {
                    var fram = Data()

                    for (_, data) in dataArray.enumerated() {
                        if data.count > 0 {
                            fram.append(data)
                        }
                    }

                    let subCmd: Subcommand = .enableStreaming
                    let cmd = self.nfcCommand(subCmd, unlockCode: self.unlockCode, patchInfo: patchInfo, sensorUID: sensorUID)

                    let streamingCommandResponse = try await tag.customCommand(requestFlags: .highDataRate, customCommandCode: Int(cmd.code), customRequestParameters: cmd.parameters)

                    var streamingEnabled = false
                    if subCmd == .enableStreaming && streamingCommandResponse.count == 6 {
                        streamingEnabled = true
                    }

                    session.invalidate()

                    let decryptedFram = PreLibre2.decryptFRAM(sensorUID: sensorUID, patchInfo: patchInfo, fram: fram)
                    if let decryptedFram = decryptedFram {
                        self.continuation?.resume(returning: Libre2Pairing(uuid: sensorUID, patchInfo: patchInfo, fram: decryptedFram, streamingEnabled: streamingEnabled))

                    } else {
                        self.continuation?.resume(returning: Libre2Pairing(uuid: sensorUID, patchInfo: patchInfo, fram: fram, streamingEnabled: streamingEnabled))
                    }
                }
            }
        }
    }

    private func nfcCommand(_ code: Subcommand, unlockCode: UInt32, patchInfo: Data, sensorUID: Data) -> NFCCommand {
        var parameters = Data([code.rawValue])

        var b: [UInt8] = []
        var y: UInt16

        if code == .enableStreaming {
            // Enables Bluetooth on Libre 2. Returns peripheral MAC address to connect to.
            // unlockCode could be any 32 bit value. The unlockCode and sensor Uid / patchInfo
            // will have also to be provided to the login function when connecting to peripheral.
            b = [
                UInt8(unlockCode & 0xFF),
                UInt8((unlockCode >> 8) & 0xFF),
                UInt8((unlockCode >> 16) & 0xFF),
                UInt8((unlockCode >> 24) & 0xFF)
            ]
            y = UInt16(patchInfo[4...5]) ^ UInt16(b[1], b[0])
        } else {
            y = 0x1b6a
        }

        if b.count > 0 {
            parameters += b
        }

        if code.rawValue < 0x20 {
            let d = PreLibre2.usefulFunction(sensorUID: sensorUID, x: UInt16(code.rawValue), y: y)
            parameters += d
        }

        return NFCCommand(code: 0xA1, parameters: parameters)
    }
}

// MARK: - fileprivate
fileprivate struct NFCCommand {
    let code: UInt8
    let parameters: Data
}

fileprivate enum Subcommand: UInt8, CustomStringConvertible {
    case activate = 0x1b
    case enableStreaming = 0x1e

    var description: String {
        switch self {
        case .activate:
            return "activate"
        case .enableStreaming:
            return "enable BLE streaming"
        }
    }
}
