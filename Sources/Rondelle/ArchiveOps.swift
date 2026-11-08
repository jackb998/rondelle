import Foundation

/// Security notes:
/// - Tools are launched by absolute path with an argument array: no shell, no $PATH lookup.
/// - File names are passed as "./name", so a file called "-TT=cmd" can never be read as an option
///   (zip's -TT and bsdtar's --use-compress-program would otherwise run arbitrary commands).
/// - Extraction uses bsdtar, which refuses ".." and absolute paths and won't write through symlinks,
///   and is preceded by a size check against archive bombs. Links in the archive that point outside
///   the extracted folder are then deleted, so they can't be used later to read or leak other files.
/// - zip stores symbolic links as links (-y): it never copies the contents of the file a link points to.
enum ArchiveOps {
    /// Refuse archives that would expand beyond this, or beyond the space returned by `extractionLimit`.
    static let maxExpandedBytes: Int64 = 50_000_000_000
    static let maxEntries = 200_000
    /// Above this expansion ratio (expanded size / archive size) the user is asked first.
    static let maxRatioWithoutAsking: Int64 = 200

    static func zip(_ urls: [URL]) throws -> [URL] {
        let first = urls[0]
        let dir = first.deletingLastPathComponent()
        let name = urls.count == 1 ? first.deletingPathExtension().lastPathComponent : L("Archivio")
        let out = FileNaming.unique(FileNaming.directory(for: first).appendingPathComponent(name).appendingPathExtension("zip"))
        // zip would try to update the claimed (empty) file as an archive: build it beside it, then move it into place.
        let temp = FileNaming.scratchName(next: out)
        FileNaming.reservations?.add(temp)
        try makeZip(urls, in: dir, to: temp)
        try FileNaming.replace(out, with: temp)
        return [out]
    }

    /// Only the files themselves: no `__MACOSX` copies of extended attributes (where a file was downloaded from,
    /// quarantine, tags), and a single file without the name of the folder it came from (0.8.1-C1, and for every
    /// ZIP since 0.8.2-X1).
    private static func makeZip(_ urls: [URL], in dir: URL, to temp: URL) throws {
        try urls.forEach { try SafeFile.refuseSpecial(inside: $0) }
        if urls.count == 1 {
            // A folder keeps its own name inside; a single file goes in alone.
            let folder = FileKind(urls[0]) == .folder
            try run("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--noextattr", "--noqtn", "--noacl"]
                    + (folder ? ["--keepParent"] : []) + [urls[0].path, temp.path])
        } else {
            try run("/usr/bin/zip", ["-r", "-q", "-X", "-y", temp.path] + urls.map(safeName), in: dir)
        }
    }

    /// One entry of a DOCX or ODT, through a file of its own that is gone when this returns.
    static func entryData(in archive: URL, entry: String, maxBytes: Int64) throws -> Data {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: file.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: file) }
        try run("/usr/bin/unzip", ["-p", archive.path, entry], stdout: file, maxOutputBytes: maxBytes)
        return try Data(contentsOf: file)
    }

    /// Replaces one entry of a package with the file of the same relative path in `folder`.
    static func update(_ archive: URL, entry: String, in folder: URL) throws {
        try run("/usr/bin/zip", ["-X", "-q", archive.path, entry], in: folder)
    }

    /// A package (DOCX) from the parts in `folder`: no owner, dates of files or other extras.
    /// `entries: false` leaves out the entries of the folders themselves (an Office package lists files only).
    static func pack(_ folder: URL, to temp: URL, folderEntries: Bool = true) throws {
        try run("/usr/bin/zip", ["-r", "-q", "-X"] + (folderEntries ? [] : ["-D"]) + [temp.path, "."], in: folder)
    }

    /// «CocoaOOXMLWriter/2775.2» in a DOCX or ODT → «Rondelle», through zip's update of that one entry (which holds
    /// only the writer's name, so nothing of the document passes through the temporary folder).
    static func neutralizeGenerator(in archive: URL, entry: String) throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = work.appendingPathComponent(entry)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        FileManager.default.createFile(atPath: file.path, contents: nil)
        try run("/usr/bin/unzip", ["-p", archive.path, entry], stdout: file)
        let original = try String(contentsOf: file, encoding: .utf8)
        let clean = original.replacingOccurrences(of: #"Cocoa[A-Za-z]*Writer/[0-9.]+"#, with: "Rondelle", options: .regularExpression)
        guard clean != original else { return }
        try clean.write(to: file, atomically: false, encoding: .utf8)
        try run("/usr/bin/zip", ["-X", "-q", archive.path, entry], in: work)
    }

    /// Below this a protected ZIP asks for confirmation; below `weakPasswordLength` the warning says why it is weak.
    static let recommendedPasswordLength = 12
    static let weakPasswordLength = 8

    /// ZIP encrypted with AES-256 (WinZip AE-1, as libarchive writes it) by the system's bsdtar. ZIP never encrypts entry names, so the
    /// files first go into a plain inner "contenuto.zip" and only that is encrypted: from outside, one neutral name.
    /// The password reaches bsdtar on its standard input (never as an argument other processes could read).
    /// Opens with The Unarchiver, Keka, 7-Zip (not the Finder); the inner ZIP then opens with a double click.
    static func protectedZip(_ urls: [URL], password: String, hint: String? = nil, hintInName: Bool = false) throws -> [URL] {
        // Short passwords are allowed (0.8.8, your choice) after the warning in `Actions.protectedZip`; empty never.
        guard !password.isEmpty else { throw OpError.failed(L("la password non può essere vuota")) }
        let first = urls[0]
        let dir = first.deletingLastPathComponent()
        let name = (urls.count == 1 ? first.deletingPathExtension().lastPathComponent : L("Archivio")) + " (\(PasswordHint.nameSuffix(hint, inName: hintInName)))"
        let out = FileNaming.unique(FileNaming.directory(for: first).appendingPathComponent(name).appendingPathExtension("zip"))
        // The inner ZIP is not encrypted: it is built in the app's own temporary folder, never next to the result,
        // where a sync service (iCloud Drive, Dropbox…) could upload it before it is deleted (C1).
        let work = protectedZipWork.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let inner = work.appendingPathComponent("contenuto.zip")
        try makeZip(urls, in: dir, to: inner)
        let temp = FileNaming.scratchName(next: out)
        FileNaming.reservations?.add(temp)
        try run("/usr/bin/tar", ["--format", "zip", "--options", "zip:encryption=aes256", "-s", "|^.*$|contenuto.zip|",
                                 "-cf", temp.path, "-C", inner.deletingLastPathComponent().path, safeName(inner)],
                input: Data((password + "\n").utf8))
        if let hint { try PasswordHint.writeToZip(temp, hint: hint) }
        try FileNaming.replace(out, with: temp)
        return [out]
    }

    /// The protected ZIPs being built; whatever a crash left there is removed at the next launch.
    static var protectedZipWork: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ZIP protetti", isDirectory: true)
    }

    static func tarGz(_ urls: [URL]) throws -> [URL] {
        let first = urls[0]
        let dir = first.deletingLastPathComponent()
        let name = urls.count == 1 ? first.deletingPathExtension().lastPathComponent : L("Archivio")
        let out = FileNaming.unique(FileNaming.directory(for: first).appendingPathComponent(name + ".tar.gz"))
        // COPYFILE_DISABLE: no ._ files; --no-xattrs/--no-mac-metadata: no extended attributes in pax headers either
        // (0.8.2-X1).
        try run("/usr/bin/tar", ["-czf", out.path, "--no-xattrs", "--no-mac-metadata", "--no-acls", "--no-fflags",
                                 "-C", dir.path] + urls.map(safeName))
        return [out]
    }

    /// ZIP, TAR, GZ, BZ2, XZ, 7Z and RAR via bsdtar (libarchive).
    /// Whether a ZIP has encrypted entries (general-purpose flag bit 0 in its central directory). Read from the
    /// end of the file only, a few KB; anything that doesn't parse counts as not encrypted (extraction then
    /// fails as before, it never succeeds wrongly).
    static func isEncryptedZip(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "zip", let handle = try? SafeFile.openForReading(url) else { return false }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size >= 22 else { return false }
        let tailLength = min(size, 65_557)   // end record (22 bytes) + the longest possible comment
        try? handle.seek(toOffset: size - tailLength)
        guard let tail = try? handle.read(upToCount: Int(tailLength)),
              let end = tail.range(of: Data([0x50, 0x4B, 0x05, 0x06]), options: .backwards) else { return false }
        func number(_ data: Data, _ at: Int, _ bytes: Int) -> UInt64 {
            (0..<bytes).reduce(0) { $0 | UInt64(data[data.startIndex + at + $1]) << (8 * UInt64($1)) }
        }
        let record = tail[end.lowerBound...]
        guard record.count >= 22 else { return false }
        let entries = min(Int(number(record, 10, 2)), maxEntries)
        let directorySize = number(record, 12, 4), directoryOffset = number(record, 16, 4)
        guard directoryOffset != 0xFFFF_FFFF, directoryOffset + directorySize <= size, directorySize <= 64_000_000 else { return false }
        try? handle.seek(toOffset: directoryOffset)
        guard let directory = try? handle.read(upToCount: Int(directorySize)) else { return false }
        var at = 0
        for _ in 0..<entries {
            guard at + 46 <= directory.count, number(directory, at, 4) == 0x0201_4B50 else { break }
            if number(directory, at + 8, 2) & 1 != 0 { return true }
            at += 46 + Int(number(directory, at + 28, 2) + number(directory, at + 30, 2) + number(directory, at + 32, 2))
        }
        return false
    }

    static func extract(_ url: URL, password: String? = nil) throws -> [URL] {
        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent.lowercased()
        let dir = FileNaming.directory(for: url)

        // A bare .gz/.bz2/.xz (not a tarball) is a single compressed file.
        let isTarball = name.hasSuffix(".tar.gz") || name.hasSuffix(".tar.bz2") || name.hasSuffix(".tar.xz") || ext == "tgz"
        if ["gz", "bz2", "xz"].contains(ext), !isTarball {
            let out = FileNaming.unique(dir.appendingPathComponent(url.deletingPathExtension().lastPathComponent))
            let tool = ["gz": "/usr/bin/gunzip", "bz2": "/usr/bin/bunzip2", "xz": "/usr/bin/xz"][ext]!
            try run(tool, ["-d", "-c", url.path], stdout: out, maxOutputBytes: extractionLimit(at: dir),
                    askAboveBytes: Int64(FileNaming.fileSize(url)) * maxRatioWithoutAsking, archiveName: url.lastPathComponent)
            return [out]
        }

        try checkExpandedSize(url, destination: dir)

        var base = url.deletingPathExtension().lastPathComponent
        if base.lowercased().hasSuffix(".tar") { base = String(base.dropLast(4)) }
        let folder = FileNaming.uniqueDirectory(dir.appendingPathComponent(base))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            // Safety net if the archive lies about its sizes: stop when the disk gets down to the margin.
            // Attributes stored in the archive (AppleDouble, pax) are not restored: a quarantine flag or a download
            // origin chosen by whoever made the archive has no business on the extracted files (0.8.2-X1).
            try expand(url, into: folder, dir: dir, password: password)
            // A protected ZIP made by Rondelle holds one plain «contenuto.zip» (names hidden): open it too.
            let inner = folder.appendingPathComponent("contenuto.zip")
            if password != nil, (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) == ["contenuto.zip"],
               (try? inner.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                try checkExpandedSize(inner, destination: dir)
                try expand(inner, into: folder, dir: dir, password: nil)
                try FileManager.default.removeItem(at: inner)
            }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return [folder]
    }

    /// bsdtar into `folder`, then the safety pass. With a password, it goes to bsdtar on its standard input.
    private static func expand(_ url: URL, into folder: URL, dir: URL, password: String?) throws {
        do {
            // Safety net if the archive lies about its sizes: stop when the disk gets down to the margin.
            // Attributes stored in the archive (AppleDouble, pax) are not restored: a quarantine flag or a download
            // origin chosen by whoever made the archive has no business on the extracted files (0.8.2-X1).
            try run("/usr/bin/tar", ["-xf", url.path, "-C", folder.path, "--exclude", "__MACOSX",
                                     "--no-xattrs", "--no-mac-metadata", "--no-acls", "--no-fflags"],
                    stopIfFreeBelow: (folder, freeSpaceMargin(at: dir)), input: password.map { Data(($0 + "\n").utf8) })
        } catch let error as OpError where password != nil {
            // bsdtar says nothing more precise without a terminal: a wrong password is by far the likeliest.
            if case .failed(let reason) = error, reason.contains("tar") {
                throw OpError.failed(L("password errata, o archivio danneggiato"))
            }
            throw error
        }
        removeEscapingLinks(in: folder)
        removeSpecialFiles(in: folder)
    }

    // MARK: Safety

    /// Deletes everything that isn't a regular file, a folder or a (remaining, internal) link:
    /// FIFOs, sockets and devices. A FIFO named "documento.pdf" would freeze whatever opens it.
    @discardableResult
    static func removeSpecialFiles(in folder: URL) -> Int {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: [.fileResourceTypeKey]) else { return 0 }
        let allowed: Set<URLFileResourceType> = [.regular, .directory, .symbolicLink]
        var removed = 0
        for case let item as URL in walker {
            let type = (try? item.resourceValues(forKeys: [.fileResourceTypeKey]))?.fileResourceType ?? .unknown
            if !allowed.contains(type) {
                try? fm.removeItem(at: item)
                removed += 1
            }
        }
        return removed
    }

    /// Deletes symbolic links that lead outside `folder` (e.g. "foto.jpg → ~/.ssh/id_rsa").
    @discardableResult
    static func removeEscapingLinks(in folder: URL) -> Int {
        let fm = FileManager.default
        let root = folder.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return 0 }
        var removed = 0
        for case let link as URL in walker {
            guard (try? link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true,
                  let target = try? fm.destinationOfSymbolicLink(atPath: link.path) else { continue }
            let resolved = (target.hasPrefix("/") ? URL(fileURLWithPath: target)
                            : link.deletingLastPathComponent().appendingPathComponent(target))
                .resolvingSymlinksInPath().standardizedFileURL.path
            if !resolved.hasPrefix(root) {
                try? fm.removeItem(at: link)
                removed += 1
            }
        }
        return removed
    }

    private static func safeName(_ url: URL) -> String { "./" + url.lastPathComponent }

    private static func freeSpace(at dir: URL) -> Int64 {
        let values = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0   // unknown: assume none (fail closed)
    }

    /// Space that must stay free after extracting: 10 GB or 10% of the free space, whichever is larger.
    /// (10% of the whole disk would block every extraction on a disk that is already fairly full.)
    static func freeSpaceMargin(at dir: URL) -> Int64 {
        max(10_000_000_000, freeSpace(at: dir) / 10)
    }

    /// Largest expansion allowed in `dir`: free space minus the margin, and never above `maxExpandedBytes`.
    static func extractionLimit(at dir: URL) -> Int64 {
        max(0, min(maxExpandedBytes, freeSpace(at: dir) - freeSpaceMargin(at: dir)))
    }

    private static func describe(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Sum of the sizes declared in the archive, read from "tar -tv --numeric-owner" in the C locale.
    /// Fail-closed: a line that doesn't parse, too many entries, an overflow or a total above `limit` throws.
    static func expandedSize(_ url: URL, limit: Int64) throws -> (total: Int64, entries: Int) {
        let listing = try capture("/usr/bin/tar", ["-tvf", url.path, "--numeric-owner"])
        var total: Int64 = 0
        var entries = 0
        for line in listing.split(separator: "\n", omittingEmptySubsequences: true) {
            // "-rw-r--r--  0 501 20  1234 Oct 19 18:16 name": mode, links, uid, gid, size, 3 date columns, name.
            let c = line.split(separator: " ", omittingEmptySubsequences: true)
            guard c.count >= 9, c[0].count == 10, Int(c[2]) != nil, Int(c[3]) != nil,
                  let size = Int64(c[4]), size >= 0 else {
                throw OpError.failed(L("il contenuto dell'archivio non è interpretabile, per sicurezza non viene estratto"))
            }
            entries += 1
            let (sum, overflow) = total.addingReportingOverflow(size)
            guard !overflow else { throw OpError.failed(L("l'archivio dichiara dimensioni impossibili")) }
            total = sum
            guard entries <= maxEntries else {   // 0.8.3-T8: the message spoke of sizes
                throw OpError.failed(L("l'archivio contiene più di %@ file: troppi per estrarlo", maxEntries))
            }
            guard total <= limit else {
                throw OpError.failed(L("l'archivio si espanderebbe a oltre %@ e %@ file: troppo grande, o lascerebbe meno di %@ liberi sul disco", describe(total), entries, describe(freeSpaceMargin(at: url.deletingLastPathComponent()))))
            }
        }
        return (total, entries)
    }

    /// Size limit, then expansion ratio: above 1:`maxRatioWithoutAsking` the user confirms.
    private static func checkExpandedSize(_ url: URL, destination: URL) throws {
        let (total, _) = try expandedSize(url, limit: extractionLimit(at: destination))
        let packed = max(Int64(FileNaming.fileSize(url)), 1)
        if total / packed > maxRatioWithoutAsking, !confirmRatio(url.lastPathComponent, packed: packed, expanded: total) {
            throw OpError.failed(L("archivio molto compresso (1:%@), estrazione annullata", total / packed))
        }
    }

    private static func confirmRatio(_ name: String, packed: Int64, expanded: Int64) -> Bool {
        Notice.confirm(
            title: L("«%@» è molto compresso", name),
            text: L("Pesa %@ ma si espanderebbe ad almeno %@ (oltre %@ volte). Capita con file vuoti o ripetitivi, ma è anche il segno di un archivio «bomba» fatto per riempire il disco. Estrarre comunque?", describe(packed), describe(expanded), maxRatioWithoutAsking),
            button: L("Estrai"))
    }

    // MARK: Processes

    /// The only environment external tools see: nothing inherited, so variables such as ZIPOPT, GZIP or
    /// TAR_WRITER_OPTIONS can't slip options in, and output formats don't depend on the user's language.
    static func minimalEnvironment() -> [String: String] {
        ["PATH": "/usr/bin:/bin", "LC_ALL": "C", "COPYFILE_DISABLE": "1"]
    }

    private static func capture(_ tool: String, _ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        process.environment = minimalEnvironment()   // also keeps the parsed listing in the C locale
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw OpError.failed(L("archivio danneggiato o non supportato")) }
        return String(decoding: data, as: UTF8.self)
    }

    /// - Parameters:
    ///   - askAboveBytes: streamed output only; past this size the user is asked once (compression ratio).
    ///   - stopIfFreeBelow: while the tool runs, stop it if the free space of that volume drops below the margin.
    private static func run(_ tool: String, _ args: [String], in dir: URL? = nil,
                            environment: [String: String] = [:], stdout: URL? = nil,
                            maxOutputBytes: Int64 = .max, askAboveBytes: Int64 = .max, archiveName: String = "",
                            stopIfFreeBelow: (volume: URL, bytes: Int64)? = nil, input: Data? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        if let dir { process.currentDirectoryURL = dir }
        process.environment = minimalEnvironment().merging(environment) { $1 }
        process.standardError = FileHandle.nullDevice

        // Streamed output (single-file decompression) is copied in chunks so it can be capped.
        var pipe: Pipe?
        var handle: FileHandle?
        if let stdout {
            FileManager.default.createFile(atPath: stdout.path, contents: nil)
            handle = try FileHandle(forWritingTo: stdout)
            pipe = Pipe()
            process.standardOutput = pipe
        }
        let feed = input.map { _ in Pipe() }
        if let feed { process.standardInput = feed }
        try process.run()
        if let feed, let input {   // e.g. a passphrase: through a pipe, not visible in the process list
            feed.fileHandleForWriting.write(input)
            try? feed.fileHandleForWriting.close()
        }

        var written: Int64 = 0
        var stopped: OpError?
        var cancelled = false
        if let pipe, let handle {
            let reader = pipe.fileHandleForReading
            var asked = false
            // Every chunk is an autoreleased buffer: without a pool per chunk they pile up until the end.
            while autoreleasepool(invoking: { () -> Bool in
                let chunk = reader.availableData
                if chunk.isEmpty { return false }
                if Task.isCancelled { cancelled = true; process.terminate(); return false }
                written += Int64(chunk.count)
                if written > maxOutputBytes {
                    stopped = .failed("il file decompresso lascerebbe troppo poco spazio libero sul disco")
                } else if written > askAboveBytes, !asked {
                    asked = true
                    let packed = askAboveBytes / maxRatioWithoutAsking
                    if !confirmRatio(archiveName, packed: packed, expanded: written) {
                        stopped = .failed("file molto compresso, decompressione annullata")
                    }
                }
                if stopped != nil { process.terminate(); return false }
                handle.write(chunk)
                return true
            }) {}
            try handle.close()
        }
        if let watch = stopIfFreeBelow {
            while process.isRunning {
                Thread.sleep(forTimeInterval: 0.2)
                if freeSpace(at: watch.volume) < watch.bytes {
                    stopped = .failed("lo spazio sul disco stava finendo: estrazione interrotta")
                    process.terminate()
                    break
                }
            }
        }
        // «Annulla»: a tool at work on a large archive must not go on to the end.
        while process.isRunning {
            if Task.isCancelled {
                cancelled = true
                process.terminate()
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        process.waitUntilExit()

        if cancelled {
            if let stdout { try? FileManager.default.removeItem(at: stdout) }
            throw CancellationError()
        }
        guard stopped == nil, process.terminationStatus == 0 else {
            if let stdout { try? FileManager.default.removeItem(at: stdout) }
            if let stopped { throw stopped }
            throw OpError.failed(L("%@ è uscito con codice %@", URL(fileURLWithPath: tool).lastPathComponent, process.terminationStatus))
        }
    }
}
