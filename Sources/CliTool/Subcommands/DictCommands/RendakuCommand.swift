import ArgumentParser
import Foundation
import KanaKanjiConverterModule

extension Subcommands.Dict {
    /// Lists the words a dictionary shows voiced as the latter element of a compound (寺 in 山寺/ヤマデラ, 駆け in 先駆け/サキガケ):
    /// the words a reading with a voiced first kana may stand for in a compound the dictionary lacks (see `RendakuData`)
    struct Rendaku: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "rendaku",
            abstract: "List the words seen voiced as the latter element of a compound in a dictionary, as a TSV (word, reading, an example compound, its reading) or as the module's RendakuData.swift."
        )

        @Option(name: [.customLong("dictionary_dir"), .customShort("d")], help: "The directory for dictionary data.")
        var dictionaryDirectory: String = "./"

        @Option(name: [.customLong("out"), .customShort("o")], help: "The TSV to write: word, reading before voicing (katakana), an example compound and its reading")
        var output: String?

        @Option(name: [.customLong("swift")], help: "The RendakuData.swift to write (Sources/KanaKanjiConverterModule/DictionaryManagement/RendakuData.swift)")
        var swiftOutput: String?

        mutating func run() throws {
            let dictionaryURL = URL(fileURLWithPath: self.dictionaryDirectory, isDirectory: true)
            let store = DicdataStore(dictionaryURL: dictionaryURL)
            let state = store.prepareState()
            let loudsDirectory = dictionaryURL.appendingPathComponent("louds", isDirectory: true)
            var entries: [Entry] = []
            let files = try FileManager.default.contentsOfDirectory(at: loudsDirectory, includingPropertiesForKeys: nil)
            for file in files where file.pathExtension == "louds" {
                let identifier = file.deletingPathExtension().lastPathComponent
                // The user's words and the memory change while running and are not the dictionary's evidence
                guard let target = Self.unescapedIdentifier(identifier), let louds = LOUDS.load(identifier, dictionaryURL: dictionaryURL) else {
                    continue
                }
                let indices = louds.prefixNodeIndices(chars: [], maxDepth: .max, maxCount: .max)
                for element in store.getDicdataFromLoudstxt3(identifier: target, indices: indices, state: state) {
                    entries.append(Entry(word: element.word, ruby: element.ruby, lcid: element.lcid))
                }
            }
            let found = Self.voicedLatterElements(of: entries)
            print("rendaku: \(entries.count) entries, \(found.count) words seen voiced as the latter element of a compound")
            if let output {
                let lines = found.map { "\($0.word)\t\($0.ruby)\t\($0.example)\t\($0.exampleRuby)" }
                try (lines.joined(separator: "\n") + "\n").write(toFile: output, atomically: true, encoding: .utf8)
            }
            if let swiftOutput {
                try Self.swiftSource(for: found).write(toFile: swiftOutput, atomically: true, encoding: .utf8)
            }
        }

        struct Entry {
            var word: String
            var ruby: String
            var lcid: Int
        }

        struct LatterElement {
            var word: String
            var ruby: String
            var example: String
            var exampleRuby: String
        }

        /// The dictionary's shard identifiers are the UTF-16 code units of the character in brackets ([3042] for あ); the
        /// user's words, the memory and the shortcuts are named as they are and are skipped
        static func unescapedIdentifier(_ identifier: String) -> String? {
            guard identifier.hasPrefix("["), identifier.hasSuffix("]") else {
                return nil
            }
            let units = identifier.dropFirst().dropLast().split(separator: "_").compactMap { UInt16($0, radix: 16) }
            guard !units.isEmpty else {
                return nil
            }
            return String(utf16CodeUnits: units, count: units.count)
        }

        /// A word (with its reading before voicing) qualifies when some entry with a kanji ends with the word and its reading
        /// ends with the word's reading voiced at the first kana. Person names are not evidence: their readings are their own
        /// (海野十三 read ウンノジュウザ would make 三 a word read ザ)
        static func voicedLatterElements(of entries: [Entry]) -> [LatterElement] {
            let known = Set(entries.map { $0.word + "\t" + $0.ruby })
            let personNames = CIDData.人名一般.cid ... CIDData.人名名.cid
            var found: [String: LatterElement] = [:]
            for entry in entries where entry.word.count >= 2 && entry.ruby.count >= 2 && !personNames.contains(entry.lcid) && Self.hasIdeograph(entry.word) {
                let word = Array(entry.word)
                let ruby = Array(entry.ruby)
                for k in 1 ..< word.count {
                    let suffix = String(word[k...])
                    guard Self.hasIdeograph(suffix) else {
                        continue
                    }
                    for j in 1 ..< ruby.count {
                        guard let voiceless = DicdataStore.voicelessOf[ruby[j]] else {
                            continue
                        }
                        let reading = String([voiceless] + ruby[(j + 1)...])
                        let key = suffix + "\t" + reading
                        if known.contains(key), found[key] == nil {
                            found[key] = LatterElement(word: suffix, ruby: reading, example: entry.word, exampleRuby: entry.ruby)
                        }
                    }
                }
            }
            return found.values.sorted { ($0.word, $0.ruby) < ($1.word, $1.ruby) }
        }

        static func hasIdeograph(_ text: String) -> Bool {
            text.unicodeScalars.contains {
                switch $0.value {
                case 0x3005, 0x3400 ... 0x4DBF, 0x4E00 ... 0x9FFF, 0xF900 ... 0xFAFF, 0x20000 ... 0x2FFFF:
                    true
                default:
                    false
                }
            }
        }

        static func swiftSource(for found: [LatterElement]) -> String {
            var lines = [
                "/// Words the bundled dictionary shows voiced as the latter element of a compound (寺 in 山寺/ヤマデラ, 駆け in 先駆け/サキガケ):",
                "/// the words a reading with a voiced first kana may stand for in a compound the dictionary lacks (夜駆け for ヨガケ), see",
                "/// `DicdataStore.rendakuPenalty`. Generated by `anco dict rendaku --swift`; each line is a word, a tab and its reading",
                "/// before voicing in katakana",
                "enum RendakuData {",
                "    static let latterElements: Set<String> = Set(Self.table.split(separator: \"\\n\").map(String.init))",
                "",
                "    private static let table = \"\"\""
            ]
            for element in found {
                lines.append("    \(element.word)\\t\(element.ruby)")
            }
            lines.append("    \"\"\"")
            lines.append("}")
            return lines.joined(separator: "\n") + "\n"
        }
    }
}
