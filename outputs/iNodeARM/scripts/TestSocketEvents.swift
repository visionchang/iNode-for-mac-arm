import Foundation
import Darwin

@main struct SocketEventsTest {
    static func main() throws {
        var pair: [Int32] = [0, 0]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        let client = FileHandle(fileDescriptor: pair[0], closeOnDealloc: true)
        let server = FileHandle(fileDescriptor: pair[1], closeOnDealloc: true)
        let readFD = dup(pair[0])
        precondition(readFD >= 0)
        let ready = DispatchSemaphore(value: 0)
        let large = DispatchSemaphore(value: 0)
        let ended = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            readSocketEvents(readFD, onEvent: { event in
                switch event["event"] as? String {
                case "ready": ready.signal()
                case "captcha":
                    precondition((event["image"] as? String)?.count == 40_000)
                    large.signal()
                default: preconditionFailure("Unexpected event")
                }
            }, onEnd: { reason in
                precondition(reason == nil, reason ?? "")
                ended.signal()
            })
        }
        try server.write(contentsOf: Data("{\"event\":\"ready\"}\n".utf8))
        precondition(ready.wait(timeout: .now() + 1) == .success,
                     "Small ready event must arrive without filling the buffer")
        print("PASS: small ready message delivered immediately")

        // Reader is now blocked waiting for more events. Writing a command must
        // still complete; it shares the socket, but not a Foundation read lock.
        let wrote = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            try! client.write(contentsOf: Data("{\"op\":\"stop\"}\n".utf8))
            wrote.signal()
        }
        precondition(wrote.wait(timeout: .now() + 1) == .success)
        var command = [UInt8](repeating: 0, count: 100)
        let count = Darwin.read(pair[1], &command, command.count)
        precondition(String(bytes: command.prefix(count), encoding: .utf8) == "{\"op\":\"stop\"}\n")
        print("PASS: command write completes while event reader is idle")

        let event = Data(("{\"event\":\"captcha\",\"image\":\"" + String(repeating: "a", count: 40_000) + "\"}\n").utf8)
        try server.write(contentsOf: event.prefix(15))
        precondition(large.wait(timeout: .now() + 0.1) == .timedOut)
        try server.write(contentsOf: event.dropFirst(15))
        precondition(large.wait(timeout: .now() + 1) == .success)
        print("PASS: fragmented large event is decoded once complete")

        shutdown(pair[0], SHUT_RDWR)
        precondition(ended.wait(timeout: .now() + 1) == .success)
        try client.close()
        try server.close()
        print("PASS: shutdown releases the blocked reader")
    }
}
