import Foundation
import Darwin
import MinitileIPC

let usage = "Usage: mntl [--json] [--socket PATH] <command...>\nRun mntl help for the command grammar."

func printReply(_ reply: Reply, json: Bool) throws {
    if json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        print(String(decoding: try encoder.encode(reply.data), as: UTF8.self))
    } else {
        print(reply.text)
    }
    fflush(stdout)
}

func run() -> Int32 {
    var args = Array(CommandLine.arguments.dropFirst())
    var json = false
    var explicitPath: String?
    while let first = args.first, first.hasPrefix("--") {
        args.removeFirst()
        switch first {
        case "--json": json = true
        case "--socket":
            guard !args.isEmpty else { fputs("--socket requires a path\n\(usage)\n", stderr); return 1 }
            explicitPath = args.removeFirst()
        case "--": break
        case "--help": print(usage); return 0
        default: fputs("Unknown option: \(first)\n\(usage)\n", stderr); return 1
        }
        if first == "--" { break }
    }
    let noArguments = args.isEmpty
    if noArguments { args = ["help"] }
    do {
        let client = Client(path: try explicitPath ?? socketPath())
        if args == ["watch"] {
            var status: Int32 = 0
            try client.watch(onReply: { reply in
                status = reply.ok ? 0 : 1
                try? printReply(reply, json: json)
            }, onEvent: { event in
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                guard let bytes = try? encoder.encode(event) else { return false }
                print(String(decoding: bytes, as: UTF8.self))
                fflush(stdout)
                return true
            })
            return status
        }
        let reply = try client.request(args)
        try printReply(reply, json: json)
        return reply.ok ? 0 : 1
    } catch IPCError.requestTooLarge {
        fputs("mntl: Request exceeds 64 KiB\n", stderr)
        return 1
    } catch {
        fputs("mntl: \(error.localizedDescription)\n", stderr)
        if noArguments { fputs("\(usage)\n", stderr) }
        return 2
    }
}

exit(run())
