#!/usr/bin/env swift
// Captures one on-screen window of a running process to a PNG, with the system shadow (-o drops it).
//   swift scripts/capture-window.swift <pid> <output.png> [title-substring]
// Picks the largest normal window of the process, or the largest whose title contains the substring.
// Needs Screen Recording permission for the terminal. Read-only: it never touches the app.
import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 3, let pid = Int32(arguments[1]) else {
    FileHandle.standardError.write(Data("usage: capture-window.swift <pid> <output.png> [title]\n".utf8))
    exit(2)
}
let output = arguments[2]
let titleFilter = arguments.count > 3 ? arguments[3] : nil

let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
    FileHandle.standardError.write(Data("could not list windows\n".utf8))
    exit(1)
}

struct Candidate {
    let id: Int
    let title: String
    let area: Double
}

var best: Candidate?
for window in windows {
    guard (window[kCGWindowOwnerPID as String] as? Int32) == pid,
          (window[kCGWindowLayer as String] as? Int) == 0,
          let id = window[kCGWindowNumber as String] as? Int,
          let bounds = window[kCGWindowBounds as String] as? [String: Double],
          let width = bounds["Width"], let height = bounds["Height"],
          width > 200, height > 200 else { continue }
    let title = window[kCGWindowName as String] as? String ?? ""
    if let titleFilter, !title.localizedCaseInsensitiveContains(titleFilter) { continue }
    let candidate = Candidate(id: id, title: title, area: width * height)
    if best == nil || candidate.area > best?.area ?? 0 { best = candidate }
}

guard let found = best else {
    FileHandle.standardError.write(Data("no matching window for pid \(pid)\n".utf8))
    exit(1)
}

let process = Process()
process.executableURL = URL(filePath: "/usr/sbin/screencapture")
process.arguments = ["-o", "-x", "-l", String(found.id), output]
do {
    try process.run()
} catch {
    FileHandle.standardError.write(Data("screencapture failed to start: \(error)\n".utf8))
    exit(1)
}
process.waitUntilExit()
print("window \(found.id) \"\(found.title)\" -> \(output) (exit \(process.terminationStatus))")
exit(process.terminationStatus)
