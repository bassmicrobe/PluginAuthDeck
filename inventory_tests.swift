// SPDX-License-Identifier: AGPL-3.0-only
// Compile: swiftc Inventory.swift inventory_tests.swift -o /tmp/auth-inventory-tests
import Foundation
import Darwin

@main
struct InventoryTests {
    static func main() throws {
        if CommandLine.arguments.count == 3 {
            let path = CommandLine.arguments[2]
            let rejected = CommandLine.arguments[1] == "--metadata-probe"
                ? Inventory.boundedData(path) == nil : Inventory.architectures(path).isEmpty
            exit(rejected ? 0 : 1)
        }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("auth-inventory-tests-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        var assertions = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            assertions += 1
            guard condition() else { fatalError("FAIL: " + message) }
        }
        func writeJSON(_ object: Any, to url: URL) throws {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
        }
        let armHeader = Data([0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0, 0, 1, 0, 0, 0, 0])
        let intelHeader = Data([0xcf, 0xfa, 0xed, 0xfe, 7, 0, 0, 1, 0, 0, 0, 0])
        func bundle(_ relative: String, id: String, components: [[String: Any]]? = nil,
                    module: [String: Any]? = nil, header: Data? = nil) throws -> URL {
            let path = root.appendingPathComponent(relative)
            let name = path.deletingPathExtension().lastPathComponent
            let binary = path.appendingPathComponent("Contents/MacOS/" + name)
            try fm.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (header ?? armHeader).write(to: binary)
            var info: [String: Any] = ["CFBundleExecutable": name, "CFBundleIdentifier": id, "CFBundleShortVersionString": "1.0"]
            if let components = components { info["AudioComponents"] = components }
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try data.write(to: path.appendingPathComponent("Contents/Info.plist"))
            if let module = module { try writeJSON(module, to: path.appendingPathComponent("Contents/Resources/moduleinfo.json")) }
            return path
        }
        func au(_ name: String, vendor: String = "Acme", subtype: String = "Synt") -> [String: Any] {
            ["name": vendor + ": " + name, "type": "aumu", "subtype": subtype, "manufacturer": "Acme", "version": 65536]
        }
        let componentRoot = root.appendingPathComponent("Components")
        let userComponentRoot = root.appendingPathComponent("UserComponents")
        let vstRoot = root.appendingPathComponent("VST3")
        let catalogRoot = root.appendingPathComponent("Catalog")
        let synthAU = try bundle("Components/Test Synth.component", id: "com.acme.test.au", components: [au("Test Synth"), au("Test Synth"), au("Bad Type", subtype: "x")])
        try fm.createDirectory(at: userComponentRoot, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: userComponentRoot.appendingPathComponent("Alias.component"), withDestinationURL: synthAU)
        let multi = try bundle("VST3/Test Synth.vst3", id: "com.acme.test.vst3", module: [
            "Factory Info": ["Vendor": "Acme"], "Classes": [
                ["Category": "Audio Module Class", "Name": "Test Synth"],
                ["Category": "Audio Module Class", "Name": "Second Synth"],
                ["Category": "Audio Module Class", "Name": "Second Synth"],
                ["Category": "Component Controller Class", "Name": "Internal Controller"]]])
        let legacy = try bundle("VST3/Repro-1.vst3", id: "com.u-he.repro.vst3", header: intelHeader)
        try Data("not a bundle".utf8).write(to: vstRoot.appendingPathComponent("Bogus.vst3"))
        let scan = { Inventory.scan(componentRoots: [componentRoot.path, userComponentRoot.path], vst3Roots: [vstRoot.path], catalogDirectory: catalogRoot) }
        var entries = scan()
        check(entries.filter { $0.format == "AU" }.count == 1, "duplicate AU declarations, symlink aliases and invalid FourCC are excluded")
        check(entries.filter { $0.format == "VST3" }.count == 2, "regular .vst3 files are not treated as bundles")
        check(entries.count == Set(entries.map(\.id)).count, "entry identifiers stay unique")
        let synth = entries.first { $0.name == "Test Synth" && $0.format == "VST3" }!
        check(synth.aliases == ["Second Synth"], "only unique audio classes become aliases; controller classes excluded")
        check(synth.searchText.contains("second synth"), "class names can be searched")
        check(synth.vendor == "Acme", "module vendor retained")
        check(synth.architectures == ["arm64"], "little endian arm64 Mach-O parsed")
        var repro = entries.first { $0.name == "Repro-1" && $0.format == "VST3" }!
        check(repro.architectures == ["x86_64"], "little endian Intel Mach-O parsed")
        check(repro.aliases.isEmpty, "unknown classes are not guessed from unrelated AU metadata")
        check(synth.enumeratedClassIDs.isEmpty, "moduleinfo names are not evidence of complete host class identifiers")
        try writeJSON([repro.id: ["stamp": repro.metadataStamp, "names": ["Repro-1", "Legacy Alias"]]],
                      to: catalogRoot.appendingPathComponent("class-catalog.json"))
        let legacyCatalogEntry = scan().first { $0.id == repro.id }!
        check(legacyCatalogEntry.aliases == ["Legacy Alias"] && legacyCatalogEntry.enumeratedClassIDs.isEmpty,
              "legacy names-only catalog remains searchable without assuming class completeness")
        let learned = Inventory.rememberClasses(for: repro, names: ["Repro-1", "Repro-5", "Repro-5", "  "], directory: catalogRoot)
        check(learned?.aliases == ["Repro-5"], "host-confirmed class names are learned without duplicates")
        check(learned?.searchText.contains("repro5") == true, "search supports punctuation-free product names")
        entries = scan()
        repro = entries.first { $0.id == repro.id }!
        check(repro.aliases == ["Repro-5"], "learned classes survive a new inventory scan")
        let complete = Inventory.rememberClasses(for: repro, names: ["Same Name", "Same Name"],
            classIDs: ["class-one", "class-two"], directory: catalogRoot)
        check(complete?.enumeratedClassIDs == ["class-one", "class-two"],
              "identical product names do not merge different class identifiers")
        var olderSnapshot = repro
        olderSnapshot.enumeratedClassIDs = ["class-one"]
        let preserved = Inventory.preservingClassMetadata(in: olderSnapshot, from: complete)
        check(preserved.enumeratedClassIDs == ["class-one", "class-two"],
              "a background refresh cannot discard a class learned since its catalog snapshot")
        var replacement = olderSnapshot
        replacement.metadataStamp = "new-binary"
        check(Inventory.preservingClassMetadata(in: replacement, from: complete).enumeratedClassIDs == ["class-one"],
              "refresh merging never imports class evidence from another binary revision")
        check(scan().first { $0.id == repro.id }?.enumeratedClassIDs == ["class-one", "class-two"],
              "complete exact class IDs survive inventory refresh")
        let smaller = Inventory.rememberClasses(for: repro, names: ["Same Name"], classIDs: ["class-one"], directory: catalogRoot)
        check(smaller?.enumeratedClassIDs == ["class-one", "class-two"],
              "a later reduced list cannot hide a class already enumerated for this binary")
        let namesOnly = Inventory.rememberClasses(for: repro, names: ["Same Name"], directory: catalogRoot)
        check(namesOnly?.enumeratedClassIDs == ["class-one", "class-two"], "names-only metadata preserves prior exact class evidence")
        check(Inventory.rememberClasses(for: repro, names: ["Same Name"], classIDs: ["class-one", ""], directory: catalogRoot) == nil,
              "malformed class lists are rejected rather than silently shortened")
        check(Inventory.rememberClasses(for: synth, names: [String(repeating: "x", count: 1025)], directory: catalogRoot) == nil,
              "oversized class names cannot bloat catalog")
        try (intelHeader + Data([1])).write(to: legacy.appendingPathComponent("Contents/MacOS/Repro-1"))
        check(Inventory.rememberClasses(for: repro, names: ["Stale Class"], directory: catalogRoot) == nil,
              "results for a replaced binary are rejected")
        check(scan().first { $0.id == repro.id }?.aliases.isEmpty == true, "changed binary invalidates learned metadata")
        check(scan().first { $0.id == repro.id }?.enumeratedClassIDs.isEmpty == true, "changed binary invalidates class completeness")
        try Data("broken json".utf8).write(to: catalogRoot.appendingPathComponent("class-catalog.json"))
        check(scan().first { $0.id == synth.id }?.aliases == ["Second Synth"], "bad cache falls back to module metadata")

        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(synth)) as! [String: Any]
        old.removeValue(forKey: "aliases"); old.removeValue(forKey: "metadataStamp"); old.removeValue(forKey: "enumeratedClassIDs")
        let decoded = try JSONDecoder().decode(Entry.self, from: JSONSerialization.data(withJSONObject: old))
        check(decoded.id == synth.id && decoded.aliases.isEmpty && decoded.metadataStamp.isEmpty && decoded.enumeratedClassIDs.isEmpty,
              "v1 inventory cache decodes and preserves favorite IDs")
        let corrupt = root.appendingPathComponent("corrupt-MachO")
        try Data([0xca, 0xfe, 0xba, 0xbe, 0xff, 0xff, 0xff, 0xff]).write(to: corrupt)
        check(Inventory.architectures(corrupt.path).isEmpty, "truncated FAT header with huge count is bounded")
        let fat = root.appendingPathComponent("fat-MachO")
        var header = Data([0xca, 0xfe, 0xba, 0xbe, 0, 0, 0, 2])
        header.append(contentsOf: [1,0,0,12] + Array(repeating: UInt8(0), count: 16))
        header.append(contentsOf: [1,0,0,7] + Array(repeating: UInt8(0), count: 16))
        try header.write(to: fat)
        check(Inventory.architectures(fat.path) == ["arm64", "x86_64"], "universal binary reports both architectures")
        let giant = root.appendingPathComponent("large.plist")
        try Data(repeating: 65, count: 4 * 1024 * 1024 + 1).write(to: giant)
        check(Inventory.plist(giant.path).isEmpty, "oversized metadata is ignored")
        let regular = root.appendingPathComponent("regular-metadata")
        try armHeader.write(to: regular)
        check(Inventory.boundedData(regular.path, limit: armHeader.count) == armHeader,
              "regular metadata is accepted exactly at the byte limit")
        check(Inventory.boundedData(regular.path, limit: armHeader.count - 1) == nil,
              "metadata one byte over the limit is rejected")
        for invalidLimit in [0, -1, Int.max] {
            check(Inventory.boundedData(regular.path, limit: invalidLimit) == nil, "invalid byte budget is rejected")
        }
        let regularAlias = root.appendingPathComponent("regular-alias")
        try fm.createSymbolicLink(at: regularAlias, withDestinationURL: regular)
        check(Inventory.boundedData(regularAlias.path) == armHeader, "regular-file aliases remain supported")
        check(Inventory.boundedData(root.path) == nil, "directory metadata is rejected")
        let sparse = root.appendingPathComponent("sparse-executable")
        try armHeader.write(to: sparse)
        let sparseHandle = try FileHandle(forWritingTo: sparse)
        try sparseHandle.truncate(atOffset: UInt64(1) << 40)
        try sparseHandle.close()
        check(Inventory.boundedData(sparse.path) == nil, "huge sparse metadata is rejected before allocation")
        check(Inventory.architectures(sparse.path) == ["arm64"], "architecture discovery reads only the bounded header of large binaries")

        // Same bundle name from two AU vendors must not mislabel the VST3 with
        // whichever vendor happened to be visited last.
        _ = try bundle("UserComponents/Test Synth.component", id: "com.other.test.au", components: [au("Test Synth", vendor: "Other", subtype: "Othr")])
        try fm.removeItem(at: multi.appendingPathComponent("Contents/Resources/moduleinfo.json"))
        check(scan().first { $0.id == synth.id }?.vendor == "acme", "ambiguous AU vendor match falls back to bundle identity")

        _ = try bundle("Components/Shared.component", id: "com.acme.shared.au",
                       components: [au("Shared", subtype: "Shr1"), au("Shared", subtype: "Shr2")])
        let sharedEntries = scan().filter { $0.name == "Shared" && $0.format == "AU" }.sorted { $0.id < $1.id }
        check(sharedEntries.count == 2 && sharedEntries[0].path == sharedEntries[1].path && sharedEntries[0].id != sharedEntries[1].id,
              "same-name AU components remain separate inventory entries")
        let firstAU = Inventory.rememberClasses(for: sharedEntries[0], names: ["Shared"], classIDs: ["au-first"], directory: catalogRoot)
        check(firstAU?.enumeratedClassIDs == ["au-first"], "AU host enumeration is retained for the selected component")
        check(Inventory.preservingClassMetadata(in: sharedEntries[1], from: firstAU).enumeratedClassIDs.isEmpty,
              "refresh merging never imports another component's classes from the same AU path")
        var refreshedShared = scan().filter { $0.path == sharedEntries[0].path }.sorted { $0.id < $1.id }
        check(refreshedShared[0].enumeratedClassIDs == ["au-first"] && refreshedShared[1].enumeratedClassIDs.isEmpty,
              "AU enumeration does not leak to another component in the same bundle")
        _ = Inventory.rememberClasses(for: sharedEntries[1], names: ["Shared"], classIDs: ["au-second"], directory: catalogRoot)
        refreshedShared = scan().filter { $0.path == sharedEntries[0].path }.sorted { $0.id < $1.id }
        check(refreshedShared[0].enumeratedClassIDs == ["au-first"] && refreshedShared[1].enumeratedClassIDs == ["au-second"],
              "each AU component keeps its own class catalog through refresh")
        let catalogURL = catalogRoot.appendingPathComponent("class-catalog.json")
        let savedCatalog = try Data(contentsOf: catalogURL)
        let oversizedNames = (0..<4096).map { String(format: "%04d", $0) + String(repeating: "x", count: 1020) }
        check(Inventory.rememberClasses(for: sharedEntries[0], names: oversizedNames, directory: catalogRoot) == nil,
              "a catalog larger than the read limit cannot replace the readable cache")
        let catalogAfterRejection = try Data(contentsOf: catalogURL)
        check(catalogAfterRejection == savedCatalog, "rejected oversized catalog preserves previous bytes")

        // A malformed bundle must not block inventory forever while opening a
        // FIFO. Run each probe in a disposable process with a strict deadline.
        let fifo = root.appendingPathComponent("metadata.fifo")
        check(mkfifo(fifo.path, mode_t(0o600)) == 0, "create writerless FIFO fixture")
        let fifoAlias = root.appendingPathComponent("fifo-alias")
        try fm.createSymbolicLink(at: fifoAlias, withDestinationURL: fifo)
        for path in [fifo, fifoAlias] {
            for mode in ["--metadata-probe", "--architecture-probe"] {
                let probe = Process()
                probe.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
                probe.arguments = [mode, path.path]
                try probe.run()
                let deadline = Date().addingTimeInterval(2)
                while probe.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
                let blocked = probe.isRunning
                if blocked { kill(probe.processIdentifier, SIGKILL) }
                probe.waitUntilExit()
                check(!blocked && probe.terminationStatus == 0, "special metadata files are rejected without blocking: " + mode)
            }
        }
        print("PASS: \(assertions) inventory/cache fixtures")
    }
}
