// Dev-only benchmark tool. Not part of the app.
// Scenarios arrive in task 2.6.

let usage = """
usage: tcbench <scenario> [options]

Dev-only benchmark tool for CleanerKit.

Scenarios:
  volume    Print volume capacity, snapshots, swap and simulator counts (read-only).
"""

if CommandLine.arguments.dropFirst().first == "volume" { await VolumeCommand.run() } else { print(usage) }
