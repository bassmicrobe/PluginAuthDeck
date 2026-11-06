// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Darwin

enum LocalFileReadError: Error {
    case missing, unreadable, tooLarge
}

/// Metadata and saved state are regular files. A FIFO/device must not block
/// startup before the caller has a chance to report or ignore malformed input.
enum LocalFileReader {
    static func read(_ path: String, maximumBytes: Int, requireCompleteFile: Bool = true) throws -> Data {
        guard maximumBytes > 0, maximumBytes < Int.max, !path.contains("\0") else {
            throw LocalFileReadError.unreadable
        }
        let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { throw LocalFileReadError.missing }
            throw LocalFileReadError.unreadable
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0 else {
            throw LocalFileReadError.unreadable
        }
        if requireCompleteFile && info.st_size > maximumBytes { throw LocalFileReadError.tooLarge }
        let expected = min(Int(info.st_size), maximumBytes)
        let data: Data
        do { data = try handle.read(upToCount: expected + (requireCompleteFile ? 1 : 0)) ?? Data() }
        catch { throw LocalFileReadError.unreadable }
        guard !requireCompleteFile || data.count <= maximumBytes else { throw LocalFileReadError.tooLarge }
        guard !requireCompleteFile || data.count == expected else { throw LocalFileReadError.unreadable }
        return data
    }
}

struct Entry: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var vendor: String
    var format: String
    var path: String
    var identifier: String
    var version: String
    var architectures: [String]
    var aliases: [String] = []
    // A cache identity defined by this app, not a DAW-specific fingerprint.
    var metadataStamp: String = ""
    // Exact IDs from a complete host enumeration for this entry and stamp.
    // Names/aliases, including moduleinfo metadata, cannot prove completeness.
    var enumeratedClassIDs: [String] = []

    var searchText: String {
        let parts = [name, vendor] + aliases
        return (parts + parts.map {
            $0.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
        }).joined(separator: " ").lowercased()
    }
}

extension Entry {
    // Version 1 caches do not have aliases or metadataStamp. Keep favorites' IDs
    // and cached lists readable across app updates.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), name: try c.decode(String.self, forKey: .name),
            vendor: try c.decode(String.self, forKey: .vendor), format: try c.decode(String.self, forKey: .format),
            path: try c.decode(String.self, forKey: .path), identifier: try c.decode(String.self, forKey: .identifier),
            version: try c.decode(String.self, forKey: .version), architectures: try c.decode([String].self, forKey: .architectures),
            aliases: try c.decodeIfPresent([String].self, forKey: .aliases) ?? [],
            metadataStamp: try c.decodeIfPresent(String.self, forKey: .metadataStamp) ?? "",
            enumeratedClassIDs: Inventory.classIDs(try c.decodeIfPresent([String].self, forKey: .enumeratedClassIDs) ?? []) ?? [])
    }
}

enum Inventory {
    static let metadataMaximumBytes = 4 * 1024 * 1024
    static let home = FileManager.default.homeDirectoryForCurrentUser.path
    static let support = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Plugin Auth Desk")

    static func boundedData(_ path: String, limit: Int = metadataMaximumBytes) -> Data? {
        try? LocalFileReader.read(path, maximumBytes: limit)
    }

    static func plist(_ path: String) -> [String: Any] {
        guard let data = boundedData(path),
              let p = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return [:] }
        return p
    }

    // Read at most 4 KiB; never execute/load a plug-in to discover architectures.
    static func architectures(_ path: String) -> [String] {
        guard let data = try? LocalFileReader.read(path, maximumBytes: 4096, requireCompleteFile: false) else { return [] }
        let b = [UInt8](data)
        func u32(_ i: Int, _ little: Bool = false) -> UInt32 {
            guard i + 4 <= b.count else { return 0 }
            let v = Array(b[i..<i+4]); let a = little ? Array(v.reversed()) : v
            return a.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        func name(_ cpu: UInt32) -> String? {
            if cpu == 0x0100000c { return "arm64" }
            if cpu == 0x01000007 { return "x86_64" }
            if cpu == 7 { return "i386" }
            return nil
        }
        let magic = u32(0)
        if magic == 0xcafebabe || magic == 0xcafebabf || magic == 0xbebafeca || magic == 0xbfbafeca {
            let little = magic == 0xbebafeca || magic == 0xbfbafeca
            let stride = magic == 0xcafebabf || magic == 0xbfbafeca ? 32 : 20
            return (0..<min(Int(u32(4, little)), 32)).compactMap { name(u32(8 + $0 * stride, little)) }
        }
        if magic == 0xcffaedfe || magic == 0xcefaedfe { return name(u32(4, true)).map { [$0] } ?? [] }
        if magic == 0xfeedfacf || magic == 0xfeedface { return name(u32(4)).map { [$0] } ?? [] }
        return []
    }

    static func bundles(root: String, ext: String) -> [String] {
        guard let e = FileManager.default.enumerator(at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return [] }
        var paths: [String] = []
        for case let url as URL in e {
            if url.pathExtension.lowercased() == ext {
                var directory: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue {
                    paths.append(url.path)
                }
                e.skipDescendants()
            } else if url.pathExtension == "app" || url.pathExtension == "bundle" {
                e.skipDescendants()
            }
        }
        return Array(Set(paths)).sorted()
    }

    struct KnownClasses: Codable {
        var stamp: String
        var names: [String]
        var classIDs: [String] = []

        init(stamp: String, names: [String], classIDs: [String] = []) {
            self.stamp = stamp; self.names = names; self.classIDs = classIDs
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            stamp = try c.decode(String.self, forKey: .stamp)
            names = try c.decode([String].self, forKey: .names)
            classIDs = Inventory.classIDs(try c.decodeIfPresent([String].self, forKey: .classIDs) ?? []) ?? []
        }
    }

    static func classCatalog(at directory: URL = support) -> [String: KnownClasses] {
        guard let data = boundedData(directory.appendingPathComponent("class-catalog.json").path),
              let catalog = try? JSONDecoder().decode([String: KnownClasses].self, from: data) else { return [:] }
        return catalog
    }

    static func names(_ values: [String], excluding name: String = "") -> [String] {
        var seen = Set<String>()
        let main = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return values.prefix(4096).compactMap { value in
            let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, clean.utf8.count <= 1024, !clean.contains("\0"),
                  clean.lowercased() != main, seen.insert(clean.lowercased()).inserted else { return nil }
            return clean
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // Reject a malformed/partial list instead of dropping bad IDs and then
    // mistaking the shortened list for a complete enumeration.
    static func classIDs(_ values: [String]) -> [String]? {
        guard !values.isEmpty, values.count <= 4096,
              values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 2048 && !$0.contains("\0")
                  && $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines) }) else { return nil }
        return Array(Set(values)).sorted()
    }

    // An inventory refresh can finish after a host has learned more classes.
    // Never replace that newer knowledge with the refresh's older snapshot.
    static func preservingClassMetadata(in scanned: Entry, from previous: Entry?) -> Entry {
        guard let previous = previous, !scanned.metadataStamp.isEmpty,
              scanned.metadataStamp == previous.metadataStamp, scanned.id == previous.id,
              scanned.path == previous.path, scanned.identifier == previous.identifier,
              scanned.format == previous.format else { return scanned }
        var merged = scanned
        merged.enumeratedClassIDs = classIDs(Array(Set(scanned.enumeratedClassIDs + previous.enumeratedClassIDs))) ?? []
        merged.aliases = names(scanned.aliases + previous.aliases, excluding: scanned.name)
        return merged
    }

    static func stamp(path: String, info: [String: Any]) -> String {
        let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let executable = info["CFBundleExecutable"] as? String ?? stem
        guard !executable.isEmpty, !executable.contains("/"), executable != ".", executable != "..",
              let attributes = try? FileManager.default.attributesOfItem(atPath: path + "/Contents/MacOS/" + executable),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else { return "" }
        let fields = ["schema": "1", "binary": executable, "size": size.stringValue,
            "modified": String(modified.timeIntervalSince1970),
            "inode": (attributes[.systemFileNumber] as? NSNumber)?.stringValue ?? "",
            "device": (attributes[.systemNumber] as? NSNumber)?.stringValue ?? "",
            "bundleID": info["CFBundleIdentifier"] as? String ?? "",
            "version": info["CFBundleShortVersionString"] as? String ?? ""]
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else { return "" }
        return data.base64EncodedString()
    }

    // Only metadata reported by the selected, running host is learned. IDs
    // must describe its complete class list; names-only callers remain valid
    // but never create completeness evidence. AU keys include the component
    // identifier, so separate components in one bundle cannot share a verdict.
    static func rememberClasses(for entry: Entry, names discovered: [String], classIDs discoveredIDs: [String]? = nil,
                                directory: URL = support) -> Entry? {
        guard ["VST3", "AU"].contains(entry.format), !entry.metadataStamp.isEmpty,
              stamp(path: entry.path, info: plist(entry.path + "/Contents/Info.plist")) == entry.metadataStamp else { return nil }
        let clean = names(discovered)
        guard !clean.isEmpty else { return nil }
        let validatedIDs = discoveredIDs.flatMap(classIDs)
        if discoveredIDs != nil && validatedIDs == nil { return nil }
        var catalog = classCatalog(at: directory)
        let previous = catalog[entry.id].flatMap { $0.stamp == entry.metadataStamp ? $0 : nil }
        // Remember every ID enumerated for this unchanged binary. A later
        // reduced list must not silently hide a previously discovered class.
        let allIDs = classIDs(Array(Set((previous?.classIDs ?? []) + (validatedIDs ?? [])))) ?? []
        catalog[entry.id] = KnownClasses(stamp: entry.metadataStamp, names: clean, classIDs: allIDs)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(catalog)
            guard data.count <= metadataMaximumBytes else { return nil }
            try data.write(to: directory.appendingPathComponent("class-catalog.json"), options: .atomic)
        } catch { return nil }
        var updated = entry
        updated.aliases = names(clean, excluding: entry.name)
        updated.enumeratedClassIDs = allIDs
        return updated
    }

    static func scan(
        componentRoots: [String] = ["/Library/Audio/Plug-Ins/Components", home + "/Library/Audio/Plug-Ins/Components"],
        vst3Roots: [String] = ["/Library/Audio/Plug-Ins/VST3", home + "/Library/Audio/Plug-Ins/VST3"],
        catalogDirectory: URL = support
    ) -> [Entry] {
        var entries: [Entry] = []
        var vendorByStem: [String: Set<String>] = [:]
        var seenAU = Set<String>()
        let catalog = classCatalog(at: catalogDirectory)
        for root in componentRoots {
            for path in bundles(root: root, ext: "component") {
                let p = plist(path + "/Contents/Info.plist")
                let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                let executable = p["CFBundleExecutable"] as? String ?? stem
                let arch = architectures(path + "/Contents/MacOS/" + executable)
                let components = p["AudioComponents"] as? [[String: Any]] ?? []
                for c in components {
                    guard let type = c["type"] as? String, let subtype = c["subtype"] as? String,
                          let manufacturer = c["manufacturer"] as? String,
                          ["aumu", "aufx", "aumf", "augn", "aumi"].contains(type),
                          subtype.utf8.count == 4, manufacturer.utf8.count == 4 else { continue }
                    let fullname = c["name"] as? String ?? stem
                    let parts = fullname.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    let vendor = parts.count > 1 ? parts[0] : manufacturer
                    let name = parts.count > 1 ? parts[1] : fullname
                    let group = type == "aumu" ? "Synths" : type == "augn" ? "Generators" : type == "aumi" ? "MidiEffects" : "Effects"
                    let identifier = "AudioUnit:\(group)/\(type),\(subtype),\(manufacturer)"
                    // Skip duplicate declarations and symlink aliases to the same
                    // physical component, but preserve genuinely different files.
                    let physicalID = URL(fileURLWithPath: path).resolvingSymlinksInPath().path + "|" + identifier
                    guard seenAU.insert(physicalID).inserted else { continue }
                    let entryID = path + "|" + identifier
                    let metadataStamp = stamp(path: path, info: p)
                    let known = catalog[entryID].flatMap { !$0.stamp.isEmpty && $0.stamp == metadataStamp ? $0 : nil }
                    entries.append(Entry(id: entryID, name: name, vendor: vendor, format: "AU",
                        path: path, identifier: identifier, version: p["CFBundleShortVersionString"] as? String ?? "", architectures: arch,
                        metadataStamp: metadataStamp, enumeratedClassIDs: known?.classIDs ?? []))
                    vendorByStem[stem.lowercased(), default: []].insert(vendor)
                    vendorByStem[name.lowercased(), default: []].insert(vendor)
                }
            }
        }
        var seenVST = Set<String>()
        for root in vst3Roots {
            for path in bundles(root: root, ext: "vst3") {
                guard seenVST.insert(URL(fileURLWithPath: path).resolvingSymlinksInPath().path).inserted else { continue }
                let p = plist(path + "/Contents/Info.plist")
                let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                let executable = p["CFBundleExecutable"] as? String ?? stem
                let arch = architectures(path + "/Contents/MacOS/" + executable)
                let moduleURL = URL(fileURLWithPath: path + "/Contents/Resources/moduleinfo.json")
                let module = boundedData(moduleURL.path).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                let factory = module?["Factory Info"] as? [String: Any]
                let candidates = vendorByStem[stem.lowercased()] ?? []
                let pairedVendor = candidates.count == 1 ? candidates.first : nil
                let factoryVendor = (factory?["Vendor"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let vendor = factoryVendor.flatMap { $0.isEmpty ? nil : $0 } ?? pairedVendor ?? vendorFromBundle(p["CFBundleIdentifier"] as? String ?? "")
                let metadataStamp = stamp(path: path, info: p)
                let classes = module?["Classes"] as? [[String: Any]] ?? []
                let declared = names(classes.filter { $0["Category"] as? String == "Audio Module Class" }.compactMap { $0["Name"] as? String })
                let known = catalog[path].flatMap { !$0.stamp.isEmpty && $0.stamp == metadataStamp ? $0 : nil }
                let aliases = names(declared.isEmpty ? known?.names ?? [] : declared, excluding: stem)
                entries.append(Entry(id: path, name: stem, vendor: vendor, format: "VST3", path: path,
                    identifier: path, version: p["CFBundleShortVersionString"] as? String ?? "", architectures: arch,
                    aliases: aliases, metadataStamp: metadataStamp, enumeratedClassIDs: known?.classIDs ?? []))
            }
        }
        return entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func vendorFromBundle(_ bundle: String) -> String {
        let p = bundle.split(separator: ".")
        guard p.count >= 2 else { return "" }
        return String(p[1])
    }

    static let managerPaths: [(String, String, String)] = [
        ("iLok License Manager", "PACE / iLok", "/Applications/iLok License Manager.app"),
        ("Native Access", "Native Instruments", "/Applications/Native Access.app"),
        ("Arturia Software Center", "Arturia", "/Applications/Arturia/Arturia Software Center.app"),
        ("Kilohearts Installer", "Kilohearts", "/Library/Application Support/Kilohearts/Kilohearts Installer.app"),
        ("Waves Central", "Waves", "/Applications/Waves Central.app"),
        ("reFX Cloud", "reFX", "/Applications/reFX Cloud.app"),
        ("KORG Software Pass", "KORG", "/Applications/KORG/KORG Software Pass.app"),
        ("Steinberg Activation Manager", "Steinberg", "/Applications/Steinberg Activation Manager.app"),
        ("UA Connect", "Universal Audio", "/Applications/UA Connect.app"),
        ("Softube Central", "Softube", "/Applications/Softube Central.app"),
        ("Plugin Alliance Installation Manager", "Plugin Alliance", "/Applications/PA-InstallationManager.app"),
        ("iZotope Product Portal", "iZotope", "/Applications/iZotope Product Portal.app"),
        ("IK Product Manager", "IK Multimedia", "/Applications/IK Product Manager.app"),
        ("IK Authorization Manager", "IK Multimedia", "/Applications/Authorization Manager.app"),
        ("UVI Portal", "UVI", "/Applications/UVI Portal.app"),
        ("XLN Online Installer", "XLN Audio", "/Applications/XLN Online Installer.app"),
        ("Auto-Tune Central", "Antares", "/Applications/Auto-Tune Central.app"),
        ("inMusic Software Center", "inMusic", "/Applications/inMusic Software Center.app"),
        ("BFD License Manager", "BFD", "/Applications/BFD License Manager.app"),
        ("A.O.M. License Manager", "A.O.M.", "/Applications/A.O.M. License Manager.app"),
        ("Caelum Audio Licence Control", "Caelum Audio", "/Applications/Caelum Audio Licence Control.app"),
        ("Antelope Launcher", "Antelope Audio", "/Applications/Antelope Launcher.app"),
        ("Cradle Hub", "Cradle", "/Applications/Cradle Hub.app"),
        ("Techivation Manager", "Techivation", "/Applications/Techivation Manager.app"),
        ("Tracktion Download Manager", "Tracktion", "/Applications/Tracktion Download Manager.app"),
        ("UJAM", "UJAM", "/Applications/UJAM.app"),
        ("SSL Download Manager", "Solid State Logic", "/Applications/SSL Download Manager.app"),
        ("Reason Companion", "Reason Studios", "/Applications/Reason Companion.app"),
        ("ROLI Connect", "ROLI", "/Applications/ROLI Connect.app"),
        ("PHIL SPEISER CONTROL CENTER", "Phil Speiser", "/Applications/PHIL SPEISER CONTROL CENTER.app"),
        ("Splice", "Splice", "/Applications/Splice.app"),
        ("Pulse", "Pulse", "/Applications/Pulse.app")
    ]

    static func managers() -> [Entry] {
        managerPaths.compactMap { name, vendor, path in
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            let p = plist(path + "/Contents/Info.plist")
            return Entry(id: path, name: name, vendor: vendor, format: "APP", path: path, identifier: path,
                version: p["CFBundleShortVersionString"] as? String ?? "", architectures: [])
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
