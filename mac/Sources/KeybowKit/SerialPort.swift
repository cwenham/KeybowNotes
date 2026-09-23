import Foundation

public enum SerialPortError: Error, CustomStringConvertible {
    case cannotOpen(path: String, errno: Int32)
    case cannotConfigure(path: String, errno: Int32)
    case writeFailed(errno: Int32)

    public var description: String {
        switch self {
        case .cannotOpen(let path, let code):
            return "cannot open \(path): \(String(cString: strerror(code)))"
        case .cannotConfigure(let path, let code):
            return "cannot configure \(path): \(String(cString: strerror(code)))"
        case .writeFailed(let code):
            return "write failed: \(String(cString: strerror(code)))"
        }
    }
}

/// A raw serial port, opened once and held open.
///
/// The firmware only writes while the host asserts DTR, so closing and reopening
/// the port between commands loses every reply. Hold one of these for as long as
/// the device is present.
public final class SerialPort {
    public let path: String
    private let fileDescriptor: Int32

    public init(path: String) throws {
        self.path = path

        let descriptor = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw SerialPortError.cannotOpen(path: path, errno: errno)
        }
        self.fileDescriptor = descriptor

        var settings = termios()
        guard tcgetattr(descriptor, &settings) == 0 else {
            close(descriptor)
            throw SerialPortError.cannotConfigure(path: path, errno: errno)
        }
        cfmakeraw(&settings)
        settings.c_cflag |= tcflag_t(CREAD | CLOCAL)
        // USB CDC ignores the baud rate, but termios still wants one.
        cfsetispeed(&settings, speed_t(B115200))
        cfsetospeed(&settings, speed_t(B115200))
        withUnsafeMutablePointer(to: &settings.c_cc) { pointer in
            pointer.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { array in
                array[Int(VMIN)] = 0
                array[Int(VTIME)] = 0
            }
        }
        guard tcsetattr(descriptor, TCSANOW, &settings) == 0 else {
            close(descriptor)
            throw SerialPortError.cannotConfigure(path: path, errno: errno)
        }

        // Raise DTR and RTS explicitly: without DTR the firmware treats us as absent.
        var lines: Int32 = TIOCM_DTR | TIOCM_RTS
        _ = ioctl(descriptor, TIOCMBIS, &lines)
    }

    deinit {
        close(fileDescriptor)
    }

    public var descriptor: Int32 { fileDescriptor }

    public func write(line: String) throws {
        let bytes = Array((line + "\n").utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { buffer in
                Foundation.write(fileDescriptor, buffer.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if written < 0 {
                if errno == EAGAIN || errno == EINTR { continue }
                throw SerialPortError.writeFailed(errno: errno)
            }
            offset += written
        }
    }

    /// Reads whatever has arrived. Returns empty when nothing is waiting.
    public func readAvailable() -> Data {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = buffer.withUnsafeMutableBytes { pointer in
            read(fileDescriptor, pointer.baseAddress, pointer.count)
        }
        guard count > 0 else { return Data() }
        return Data(buffer[0..<count])
    }
}

/// Splits a byte stream into lines, holding on to any partial tail.
public struct LineAssembler {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let raw = buffer[buffer.startIndex..<newline]
            buffer = buffer[buffer.index(after: newline)...]
            if let text = String(data: raw, encoding: .utf8) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { lines.append(trimmed) }
            }
        }
        return lines
    }
}
