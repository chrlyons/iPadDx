import Foundation
import Network

/// Flutter platform channel transport — replicates the overhead of Flutter's
/// MethodChannel binary serialization and platform thread dispatch.
///
/// Real Flutter apps use:
///   Dart: MethodChannel('plugin').invokeMethod('send', data)
///     → Dart StandardMethodCodec encodes to binary
///     → FlutterEngine dispatches to platform thread
///     → [Thread context switch: UI thread → platform thread]
///     → FlutterMethodChannel handler receives binary data
///     → StandardMethodCodec decodes binary
///     → Plugin processes
///     → StandardMethodCodec encodes result
///     → [Thread context switch: platform thread → UI thread]
///     → Dart StandardMethodCodec decodes result
///     → Future completes
///
/// This transport cannot embed the Dart VM (it's a compiled C++ binary requiring
/// the Flutter SDK), but it faithfully replicates the two measurable overhead
/// sources: StandardMethodCodec binary serialization AND the platform thread
/// dispatch hop. Together these account for the majority of platform channel
/// latency in real Flutter apps.
final class FlutterTransport: TransportProvider {
    let bridgeID = "flutter"
    let bridgeLabel = "Flutter Channel"

    var onStateChange: ((TransportState) -> Void)?

    private let native = NativeTransport()

    /// Simulates the platform thread that Flutter dispatches MethodChannel calls to.
    /// Real Flutter apps hop from the UI thread to the platform thread and back.
    private let platformThread = DispatchQueue(label: "com.ipadconnection.flutter-platform-thread")

    var currentPath: NWPath? {
        native.currentPath
    }

    func connect(to endpoint: NWEndpoint, queue: DispatchQueue) {
        native.onStateChange = { [weak self] state in
            self?.onStateChange?(state)
        }
        native.connect(to: endpoint, queue: queue)
    }

    func accept(_ connection: NWConnection, queue: DispatchQueue) {
        native.onStateChange = { [weak self] state in
            self?.onStateChange?(state)
        }
        native.accept(connection, queue: queue)
    }

    func send(_ data: Data, completion: @escaping (NWError?) -> Void) {
        // 1. Dart side: StandardMethodCodec encodes the method call
        let encoded = FlutterCodec.encodeMethodCall(method: "send", argument: data)

        // 2. FlutterEngine dispatches to platform thread (thread context switch)
        platformThread.async { [weak self] in
            // 3. Platform thread: StandardMethodCodec decodes
            let decoded = FlutterCodec.decodeMethodCall(encoded)

            // 4. Plugin processes, encodes result
            let resultEncoded = FlutterCodec.encodeSuccessEnvelope(decoded.argument)

            // 5. Dispatch back to "UI thread" (second context switch)
            DispatchQueue.main.async {
                // 6. Dart side: decode the result
                let result = FlutterCodec.decodeEnvelope(resultEncoded)

                self?.native.send(result, completion: completion)
            }
        }
    }

    func startReceiving(
        handler: @escaping (Data) -> Void,
        onEOF: @escaping () -> Void,
        onError: @escaping (NWError) -> Void
    ) {
        native.startReceiving(
            handler: { [weak self] payload in
                // Same double thread hop for received data
                let encoded = FlutterCodec.encodeMethodCall(method: "onData", argument: payload)

                self?.platformThread.async {
                    let decoded = FlutterCodec.decodeMethodCall(encoded)
                    let resultEncoded = FlutterCodec.encodeSuccessEnvelope(decoded.argument)

                    DispatchQueue.main.async {
                        let result = FlutterCodec.decodeEnvelope(resultEncoded)
                        handler(result)
                    }
                }
            },
            onEOF: onEOF,
            onError: onError
        )
    }

    func disconnect() {
        native.disconnect()
    }
}

// MARK: - Flutter StandardMethodCodec Simulation

/// Replicates Flutter's StandardMethodCodec binary serialization.
/// See: https://api.flutter.dev/flutter/services/StandardMethodCodec-class.html
///
/// The format is:
/// - Method call: [type byte] [method name length (uint16)] [method name UTF8] [argument bytes]
/// - Success envelope: [0x00] [result bytes]
/// - Error envelope: [0x01] [error code] [error message] [error details]
enum FlutterCodec {
    // Type tags matching Flutter's StandardMessageCodec
    static let typeNull: UInt8 = 0
    static let typeTrue: UInt8 = 1
    static let typeFalse: UInt8 = 2
    static let typeInt32: UInt8 = 3
    static let typeInt64: UInt8 = 4
    static let typeFloat64: UInt8 = 6
    static let typeString: UInt8 = 7
    static let typeUint8List: UInt8 = 8

    struct MethodCall {
        let method: String
        let argument: Data
    }

    /// Encode a method call in StandardMethodCodec binary format.
    static func encodeMethodCall(method: String, argument: Data) -> Data {
        var buffer = Data()

        // Write method name as typed string
        buffer.append(typeString)
        let methodBytes = Array(method.utf8)
        writeSize(methodBytes.count, to: &buffer)
        buffer.append(contentsOf: methodBytes)

        // Write argument as typed byte array
        buffer.append(typeUint8List)
        writeSize(argument.count, to: &buffer)
        buffer.append(argument)

        return buffer
    }

    /// Decode a method call from StandardMethodCodec binary format.
    static func decodeMethodCall(_ data: Data) -> MethodCall {
        var offset = 0

        // Read method name
        guard offset < data.count, data[offset] == typeString else {
            return MethodCall(method: "", argument: data)
        }
        offset += 1
        let methodLen = readSize(from: data, at: &offset)
        let methodEnd = min(offset + methodLen, data.count)
        let method = String(bytes: data[offset ..< methodEnd], encoding: .utf8) ?? ""
        offset = methodEnd

        // Read argument
        guard offset < data.count, data[offset] == typeUint8List else {
            return MethodCall(method: method, argument: Data())
        }
        offset += 1
        let argLen = readSize(from: data, at: &offset)
        let argEnd = min(offset + argLen, data.count)
        let argument = Data(data[offset ..< argEnd])

        return MethodCall(method: method, argument: argument)
    }

    /// Encode a success result envelope.
    static func encodeSuccessEnvelope(_ result: Data) -> Data {
        var buffer = Data()
        buffer.append(0x00) // success marker
        buffer.append(typeUint8List)
        writeSize(result.count, to: &buffer)
        buffer.append(result)
        return buffer
    }

    /// Decode a result envelope, returning the payload.
    static func decodeEnvelope(_ data: Data) -> Data {
        guard !data.isEmpty, data[0] == 0x00 else { return data }
        var offset = 1
        guard offset < data.count, data[offset] == typeUint8List else { return data }
        offset += 1
        let len = readSize(from: data, at: &offset)
        let end = min(offset + len, data.count)
        return Data(data[offset ..< end])
    }

    // MARK: - Size encoding (matches Flutter's variable-length size encoding)

    private static func writeSize(_ size: Int, to buffer: inout Data) {
        if size < 254 {
            buffer.append(UInt8(size))
        } else if size < 65536 {
            buffer.append(254)
            var s = UInt16(size)
            buffer.append(Data(bytes: &s, count: 2))
        } else {
            buffer.append(255)
            var s = UInt32(size)
            buffer.append(Data(bytes: &s, count: 4))
        }
    }

    private static func readSize(from data: Data, at offset: inout Int) -> Int {
        guard offset < data.count else { return 0 }
        let first = data[offset]
        offset += 1
        if first < 254 {
            return Int(first)
        } else if first == 254 {
            guard offset + 2 <= data.count else { return 0 }
            let size = data[offset ..< offset + 2].withUnsafeBytes { $0.load(as: UInt16.self) }
            offset += 2
            return Int(size)
        } else {
            guard offset + 4 <= data.count else { return 0 }
            let size = data[offset ..< offset + 4].withUnsafeBytes { $0.load(as: UInt32.self) }
            offset += 4
            return Int(size)
        }
    }
}
