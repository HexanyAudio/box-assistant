import Foundation

struct Request: Decodable {
    let type: String
    let id: String
}

struct Response: Encodable {
    var ok: Bool
    var path: String?
    var revealed: String?
    var error: String?

    static func failure(_ code: String) -> Response { Response(ok: false, error: code) }
}

// MARK: - Core

func handle(_ req: Request, reveal doReveal: Bool) -> Response {
    guard let type = ItemType(named: req.type) else { return .failure("bad_request") }
    guard !req.id.isEmpty, req.id.allSatisfy(\.isNumber) else { return .failure("bad_request") }

    let resolver: PathResolver
    do {
        resolver = try PathResolver()
    } catch let e as ResolveError {
        return .failure(e.rawValue)
    } catch {
        return .failure("box_not_running")
    }
    defer { resolver.close() }

    let url: URL
    do {
        url = try resolver.resolve(id: req.id, type: type)
    } catch let e as ResolveError {
        return .failure(e.rawValue)
    } catch {
        return .failure("not_found")
    }

    if FileManager.default.fileExists(atPath: url.path) {
        if doReveal { Reveal.inFinder(url) }
        return Response(ok: true, path: url.path, revealed: doReveal ? url.path : nil)
    }

    // Box knows the item but it isn't on disk yet. Reveal the closest ancestor
    // that does exist so the click still lands somewhere useful, and report why.
    if let fallback = resolver.nearestExisting(url) {
        if doReveal { Reveal.inFinder(fallback) }
        return Response(
            ok: false,
            path: url.path,
            revealed: doReveal ? fallback.path : nil,
            error: "not_synced"
        )
    }
    return Response(ok: false, path: url.path, error: "not_synced")
}

extension ItemType {
    init?(named: String) {
        switch named {
        case "folder": self = .folder
        case "file": self = .file
        default: return nil
        }
    }
}

// MARK: - Native messaging framing

/// Chrome frames every message with a 4-byte little-endian length prefix.
func readNativeMessage() -> Data? {
    let stdin = FileHandle.standardInput
    guard let header = try? stdin.read(upToCount: 4), header.count == 4 else { return nil }
    let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
    guard length > 0, length <= 1_048_576 else { return nil }
    guard let body = try? stdin.read(upToCount: Int(length)), body.count == Int(length) else {
        return nil
    }
    return body
}

func writeNativeMessage(_ data: Data) {
    var length = UInt32(data.count).littleEndian
    var out = Data(bytes: &length, count: 4)
    out.append(data)
    FileHandle.standardOutput.write(out)
}

func encode(_ response: Response) -> Data {
    (try? JSONEncoder().encode(response)) ?? Data(#"{"ok":false,"error":"encode_failed"}"#.utf8)
}

// MARK: - Entry point

let args = Array(CommandLine.arguments.dropFirst())
let dryRun = args.contains("--dry-run")

if let i = args.firstIndex(of: "--verify") {
    // Resolve a random sample of real items and confirm each path exists on disk.
    let count = Int(args.indices.contains(i + 1) ? args[i + 1] : "200") ?? 200
    guard let resolver = try? PathResolver() else {
        FileHandle.standardError.write(Data("cannot open Box metadata\n".utf8))
        exit(2)
    }
    defer { resolver.close() }

    // Two independent checks, deliberately separated. Resolving an ID against the
    // metadata is pure local SQL and takes microseconds. Confirming the path on
    // disk goes through Box's File Provider, which costs a network round trip
    // (~0.7s) for any path not already cached — so it gets a much smaller sample.
    let checkFS = !args.contains("--no-fs")
    let items = resolver.sampleItems(limit: count)
    var resolved = 0, unresolved = 0, onDisk = 0, missing = 0
    let quiet = args.contains("--quiet")

    for (n, item) in items.enumerated() {
        guard let url = try? resolver.resolve(id: item.id, type: item.type) else {
            unresolved += 1
            if !quiet, unresolved <= 10 { print("UNRESOLVED  \(item.type) \(item.id)") }
            continue
        }
        resolved += 1
        guard checkFS else { continue }

        if FileManager.default.fileExists(atPath: url.path) {
            onDisk += 1
        } else {
            missing += 1
            if !quiet, missing <= 10 { print("MISSING  \(item.type) \(item.id)  \(url.path)") }
        }
        if (n + 1) % 25 == 0 {
            print("  …\(n + 1)/\(items.count)")
            fflush(stdout)
        }
    }

    print("sync root: \(resolver.syncRoot.path)")
    print("sampled \(items.count): \(resolved) resolved, \(unresolved) unresolved")
    if checkFS { print("filesystem: \(onDisk) present, \(missing) missing") }
    exit(unresolved == 0 && missing == 0 ? 0 : 1)
}

if args.contains("--debug") {
    // Plain JSON in, plain JSON out — no length framing, for testing from a shell.
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard let req = try? JSONDecoder().decode(Request.self, from: input) else {
        print(String(decoding: encode(.failure("bad_request")), as: UTF8.self))
        exit(1)
    }
    let response = handle(req, reveal: !dryRun)
    print(String(decoding: encode(response), as: UTF8.self))
    exit(response.ok ? 0 : 1)
}

// Native messaging: serve messages until Chrome closes the pipe. This covers both
// sendNativeMessage (one message, then EOF) and a long-lived connectNative port.
while let body = readNativeMessage() {
    guard let req = try? JSONDecoder().decode(Request.self, from: body) else {
        writeNativeMessage(encode(.failure("bad_request")))
        continue
    }
    writeNativeMessage(encode(handle(req, reveal: !dryRun)))
}
