import Foundation

/// Spike S3 entry point: `s3trash <mountpoint> [results.jsonl]`.
/// Every trash call is aimed at `<mountpoint>/work` only; see Support.swift for the guards.
@main
struct S3Trash {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count == 2 || args.count == 3 else {
            FileHandle.standardError.write(Data("usage: s3trash <mountpoint> [results.jsonl]\n".utf8))
            exit(2)
        }
        Recorder.shared.open(path: args.count == 3 ? args[2] : "results.jsonl")
        let env = makeEnv(mountArgument: args[1])

        do {
            try FileManager.default.createDirectory(at: env.work, withIntermediateDirectories: true)
        } catch {
            abortRun("cannot create work dir: \(error)")
        }
        let started = ContinuousClock.now

        await onBackgroundQueue { runBackgroundCases(env: env) }
        await runMainActorCases(env: env)
        await putBackSummary(env: env)

        let entries = (try? FileManager.default.contentsOfDirectory(atPath: env.trash.path)) ?? []
        Recorder.shared.write([
            "case": "done",
            "trashEntryCount": entries.count,
            "totalSeconds": milliseconds(ContinuousClock.now - started) / 1000,
        ])
        log("done")
    }
}
