import Foundation

/// Versioned control and audio frames shared by the Mac receiver and iPhone sender.
public enum MicMuxWire {
  public static let alpn = Data("audio.micmux/1".utf8)
  public static let version = 1
  public static let maximumDatagramSamples = 480
  public static let maximumControlBytes = 16_384

  private static let audioMagic: [UInt8] = [0x4D, 0x4D, 0x58, 0x41]  // MMXA

  public struct PairingInvitation: Equatable {
    public let ticket: String
    public let secret: Data
    public let receiverName: String

    public init(ticket: String, secret: Data, receiverName: String) throws {
      guard !ticket.isEmpty, secret.count >= 16, !receiverName.isEmpty else {
        throw WireError.invalidInvitation
      }
      self.ticket = ticket
      self.secret = secret
      self.receiverName = receiverName
    }

    public var urlString: String {
      var components = URLComponents()
      components.scheme = "micmux"
      components.host = "pair"
      components.queryItems = [
        URLQueryItem(name: "v", value: String(MicMuxWire.version)),
        URLQueryItem(name: "ticket", value: ticket),
        URLQueryItem(name: "secret", value: secret.base64URLString),
        URLQueryItem(name: "name", value: receiverName),
      ]
      return components.string ?? ""
    }

    public static func parse(_ value: String) throws -> PairingInvitation {
      guard
        let components = URLComponents(
          string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
        components.scheme == "micmux",
        components.host == "pair",
        components.value(named: "v") == String(MicMuxWire.version),
        let ticket = components.value(named: "ticket"),
        let secretValue = components.value(named: "secret"),
        let secret = Data(base64URLString: secretValue),
        let name = components.value(named: "name")
      else {
        throw WireError.invalidInvitation
      }
      return try PairingInvitation(ticket: ticket, secret: secret, receiverName: name)
    }
  }

  public struct Hello: Codable, Equatable, Sendable {
    public let version: Int
    public let secret: Data
    public let sourceID: String
    public let sourceName: String
    public let routeKind: String
    public let sampleRate: Double

    public init(
      secret: Data,
      sourceID: String,
      sourceName: String,
      routeKind: String,
      sampleRate: Double
    ) {
      version = MicMuxWire.version
      self.secret = secret
      self.sourceID = sourceID
      self.sourceName = sourceName
      self.routeKind = routeKind
      self.sampleRate = sampleRate
    }
  }

  public struct Acknowledgement: Codable, Equatable, Sendable {
    public let accepted: Bool
    public let message: String

    public init(accepted: Bool, message: String) {
      self.accepted = accepted
      self.message = message
    }
  }

  public struct AudioPacket: Equatable, Sendable {
    public let sequence: UInt64
    public let sampleRate: UInt32
    public let samples: [Float]

    public init(sequence: UInt64, sampleRate: UInt32, samples: [Float]) throws {
      guard sampleRate > 0, !samples.isEmpty, samples.count <= MicMuxWire.maximumDatagramSamples
      else {
        throw WireError.invalidAudioPacket
      }
      self.sequence = sequence
      self.sampleRate = sampleRate
      self.samples = samples
    }

    public func encode() -> Data {
      var data = Data(MicMuxWire.audioMagic)
      data.append(UInt8(MicMuxWire.version))
      data.append(0)
      data.appendBigEndian(sequence)
      data.appendBigEndian(sampleRate)
      data.appendBigEndian(UInt16(samples.count))
      for sample in samples {
        let clipped = max(-1, min(1, sample))
        data.appendBigEndian(UInt16(bitPattern: Int16((clipped * Float(Int16.max)).rounded())))
      }
      return data
    }

    public static func decode(_ data: Data) throws -> AudioPacket {
      let minimumBytes = 20
      guard data.count >= minimumBytes,
        Array(data.prefix(4)) == MicMuxWire.audioMagic,
        data[4] == UInt8(MicMuxWire.version)
      else {
        throw WireError.invalidAudioPacket
      }
      var reader = ByteReader(data: data, offset: 6)
      let sequence: UInt64 = try reader.readBigEndian()
      let sampleRate: UInt32 = try reader.readBigEndian()
      let count: UInt16 = try reader.readBigEndian()
      guard count > 0,
        Int(count) <= MicMuxWire.maximumDatagramSamples,
        reader.remaining == Int(count) * MemoryLayout<UInt16>.size
      else {
        throw WireError.invalidAudioPacket
      }
      var samples: [Float] = []
      samples.reserveCapacity(Int(count))
      for _ in 0..<count {
        let bits: UInt16 = try reader.readBigEndian()
        samples.append(Float(Int16(bitPattern: bits)) / Float(Int16.max))
      }
      return try AudioPacket(sequence: sequence, sampleRate: sampleRate, samples: samples)
    }
  }

  public static func encodeControl<T: Encodable>(_ value: T) throws -> Data {
    let body = try JSONEncoder().encode(value)
    guard body.count <= maximumControlBytes else { throw WireError.controlMessageTooLarge }
    var framed = Data()
    framed.appendBigEndian(UInt32(body.count))
    framed.append(body)
    return framed
  }

  public static func controlBodyLength(from header: Data) throws -> Int {
    guard header.count == MemoryLayout<UInt32>.size else { throw WireError.invalidControlMessage }
    var reader = ByteReader(data: header)
    let length: UInt32 = try reader.readBigEndian()
    guard length > 0, length <= maximumControlBytes else {
      throw WireError.controlMessageTooLarge
    }
    return Int(length)
  }

  public enum WireError: LocalizedError {
    case controlMessageTooLarge
    case invalidAudioPacket
    case invalidControlMessage
    case invalidInvitation

    public var errorDescription: String? {
      switch self {
      case .controlMessageTooLarge: return "The MicMux control message is too large."
      case .invalidAudioPacket: return "The MicMux audio packet is malformed."
      case .invalidControlMessage: return "The MicMux control message is malformed."
      case .invalidInvitation: return "This is not a valid MicMux pairing invitation."
      }
    }
  }
}

private struct ByteReader {
  let data: Data
  var offset = 0

  var remaining: Int { data.count - offset }

  mutating func readBigEndian<T: FixedWidthInteger>() throws -> T {
    let size = MemoryLayout<T>.size
    guard remaining >= size else { throw MicMuxWire.WireError.invalidAudioPacket }
    var value: T = 0
    for byte in data[offset..<(offset + size)] {
      value = (value << 8) | T(byte)
    }
    offset += size
    return value
  }
}

extension Data {
  fileprivate init?(base64URLString: String) {
    var value = base64URLString.replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    value += String(repeating: "=", count: (4 - value.count % 4) % 4)
    self.init(base64Encoded: value)
  }

  fileprivate var base64URLString: String {
    base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  fileprivate mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
    var bigEndian = value.bigEndian
    Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
  }
}

extension URLComponents {
  fileprivate func value(named name: String) -> String? {
    queryItems?.first(where: { $0.name == name })?.value
  }
}
