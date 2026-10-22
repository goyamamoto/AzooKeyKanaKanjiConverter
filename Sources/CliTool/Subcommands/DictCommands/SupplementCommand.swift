import ArgumentParser
import Foundation
import KanaKanjiConverterModule

extension Subcommands.Dict {
    /// Builds a supplementary dictionary (words the bundled dictionary lacks; see `ConvertRequestOptions.supplementaryDictionaryURL`)
    /// from a TSV of ruby (katakana), word, cid, mid and value
    struct Supplement: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "supplement",
            abstract: "Build the LOUDS files of a supplementary dictionary from a TSV (ruby, word, cid, mid, value)."
        )

        @Argument(help: "The TSV: ruby in katakana, word, cid, mid, value, one entry per line")
        var source: String

        @Option(name: [.customLong("out"), .customShort("o")], help: "The directory to write supplement.louds, supplement.loudschars2 and supplement<n>.loudstxt3 into")
        var outputDirectory: String

        @Option(name: [.customLong("char_id")], help: "The bundled dictionary's louds/charID.chid, which fixes the character ids")
        var charIDFile: String

        mutating func run() throws {
            let supported = Set(try String(contentsOfFile: self.charIDFile, encoding: .utf8))
            var entries: [DicdataElement] = []
            var skipped = 0
            for line in try String(contentsOfFile: self.source, encoding: .utf8).split(separator: "\n") {
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard fields.count == 5, let cid = Int(fields[2]), let mid = Int(fields[3]), let value = Float(fields[4]) else {
                    skipped += 1
                    continue
                }
                let ruby = String(fields[0])
                guard !ruby.isEmpty, ruby.allSatisfy(supported.contains) else {
                    skipped += 1
                    continue
                }
                entries.append(DicdataElement(word: String(fields[1]), ruby: ruby, cid: cid, mid: mid, value: PValue(value)))
            }
            let outputURL = URL(fileURLWithPath: self.outputDirectory, isDirectory: true)
            try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
            try DictionaryBuilder.exportDictionary(
                entries: entries,
                to: outputURL,
                baseName: "supplement",
                shardByFirstCharacter: false,
                charIDFileURL: URL(fileURLWithPath: self.charIDFile)
            )
            print("supplement: \(entries.count) entries written to \(outputURL.path), \(skipped) lines skipped")
        }
    }
}
