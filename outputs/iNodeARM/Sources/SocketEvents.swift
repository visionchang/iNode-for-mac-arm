import Foundation
import Darwin

// Owns fd. read(2) returns available stream bytes immediately; Foundation's
// read(upToCount:) may wait to fill its requested buffer on macOS sockets.
func readSocketEvents(_ fd: Int32,
                      onEvent: ([String: Any]) -> Void,
                      onEnd: (String?) -> Void) {
    defer { Darwin.close(fd) }
    var pending = Data()
    var buffer = [UInt8](repeating: 0, count: 8192)
    do {
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            if count == 0 { break }
            pending.append(contentsOf: buffer.prefix(count))
            guard pending.count <= 1_100_000 else {
                throw NSError(domain: "IPC", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "VPN 核心消息过大"])
            }
            while let newline = pending.firstIndex(of: 10) {
                let line = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                guard let event = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw NSError(domain: "IPC", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "VPN 核心消息格式错误"])
                }
                onEvent(event)
            }
        }
        onEnd(nil)
    } catch { onEnd(error.localizedDescription) }
}
