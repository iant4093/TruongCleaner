import Foundation

let startedAt = Date()
let report = Report.build(startedAt: startedAt)

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

do {
    let data = try encoder.encode(report)
    let file = try Report.write(data, startedAt: startedAt)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
    Report.log("wrote \(file.path)")
} catch {
    Report.log("failed: \(error)")
    exit(1)
}
