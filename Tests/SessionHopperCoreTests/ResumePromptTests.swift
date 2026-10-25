import XCTest
@testable import SessionHopperCore

/// Whether a moved session resumes with a continue prompt: transcript tail rule, prompt template, doctor parsing.
final class ResumePromptTests: XCTestCase {
    let sb = Sandbox()

    // Transcript lines as Claude Code writes them (only the fields the rule reads).
    let prompt = #"{"type":"user","message":{"content":"fix the tests"}}"#
    let toolUse = #"{"type":"assistant","message":{"stop_reason":"tool_use","content":[{"type":"tool_use","name":"Bash"}]}}"#
    let toolResult = #"{"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]}}"#
    let reply = #"{"type":"assistant","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"Done."}]}}"#
    let stopSummary = #"{"type":"system","subtype":"stop_hook_summary"}"#
    let noise = #"{"type":"attachment","attachment":{"type":"hook_success"}}"#

    func finished(_ lines: [String]) -> Bool {
        sb.write(lines.joined(separator: "\n") + "\n", "t.jsonl")
        return Transcripts.turnFinished(sb.root.appendingPathComponent("t.jsonl"))
    }

    func testTurnFinishedFromTranscriptTail() {
        XCTAssertTrue(finished([prompt, toolUse, toolResult, reply, noise, stopSummary]), "a reply then the Stop marker")
        XCTAssertTrue(finished([prompt, reply]), "an end_turn reply is enough (turn_duration is not always written)")
        XCTAssertFalse(finished([prompt, toolUse, toolResult, noise]), "cut off after a tool result (the 2026-10-25 case)")
        XCTAssertFalse(finished([prompt, toolUse]), "a tool call that never returned")
        XCTAssertFalse(finished([reply, prompt]), "a prompt that never got its reply")
        XCTAssertTrue(finished([prompt, toolUse, toolResult,
                                #"{"type":"user","message":{"content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}"#,
                                #"{"type":"system","subtype":"turn_duration"}"#]), "Esc: the user stopped it, nothing to redo")
        XCTAssertTrue(finished([prompt, toolResult, #"{"type":"assistant","message":{"stop_reason":"stop_sequence","content":[{"type":"text","text":"No response requested."}]}}"#]),
                      "Claude Code's resume placeholder closes an earlier cut-off")
        XCTAssertFalse(finished([prompt, #"{"type":"assistant","isApiErrorMessage":true,"message":{"content":[{"type":"text","text":"API Error"}]}}"#]))
        XCTAssertTrue(finished([prompt, reply, #"{"type":"user","message":{"content":"/compact keep it short"}}"#,
                                #"{"type":"user","isCompactSummary":true,"message":{"content":"This session is being continued"}}"#]), "slash commands and summaries don't decide")
        XCTAssertTrue(finished([prompt, reply, #"{"type":"user","message":{"content":"<local-command-stdout>ok</local-command-stdout>"}}"#,
                                #"{"type":"user","isMeta":true,"message":{"content":"skill text"}}"#]))
        XCTAssertTrue(finished([prompt, reply, #"{"type":"user","isSidechain":true,"message":{"content":[{"type":"tool_result"}]}}"#]), "subagent lines are not the main turn")
        XCTAssertTrue(finished([noise]), "nothing recognisable: no prompt")
        XCTAssertTrue(Transcripts.turnFinished(nil), "no transcript: no prompt")
        XCTAssertTrue(finished(["{\"type\":\"user\",\"message\":{\"conte", reply]), "a cut first line is skipped")
    }

    func testDefaultPromptKeepsItsText() {
        let p = LaunchPlan.continuePrompt(jobs: ["shell b1 - tail -f build.log"], limitStop: false)
        XCTAssertTrue(p.hasPrefix("[sessionhopper] This conversation was moved"))
        XCTAssertTrue(p.contains("\n\nBackground jobs that were still running:\n- shell b1 - tail -f build.log\n\nDo this, in order:\n1. Re-read"))
        XCTAssertFalse(p.contains("{"), "no placeholder left behind")
        XCTAssertFalse(p.contains("Scheduled tasks"))
    }

    func testCronsAndOwnTemplate() {
        let p = LaunchPlan.continuePrompt(jobs: [], crons: ["7 10 * * * (recurring) - check the branch"], limitStop: true)
        XCTAssertTrue(p.contains("usage limit"))
        XCTAssertTrue(p.contains("Run CronList first and re-create only what is missing:\n- 7 10 * * * (recurring) - check the branch"))
        let own = LaunchPlan.continuePrompt(jobs: ["j"], limitStop: false, from: "work", to: "home",
                                            template: "Moved {from} -> {to}. {reason}{jobs}{crons} Go on.")
        XCTAssertTrue(own.hasPrefix("[sessionhopper] Moved work -> home. This conversation was moved"))
        XCTAssertTrue(own.hasSuffix("- j Go on."))
        XCTAssertEqual(LaunchPlan.continuePrompt(jobs: [], limitStop: false, template: "  \n"),
                       LaunchPlan.continuePrompt(jobs: [], limitStop: false), "an empty template means the built-in one")
    }

    func testOwnPromptRoundTripsInConfig() throws {
        var c = HopperConfig()
        c.continuePrompt = "Carry on. {reason}"
        let back = try JSONDecoder().decode(HopperConfig.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back.continuePrompt, "Carry on. {reason}")
        XCTAssertNil(try JSONDecoder().decode(HopperConfig.self, from: Data(#"{"suggestThreshold":80}"#.utf8)).continuePrompt)
    }

    func testStopRecordsScheduledTasks() {
        let sid = "22222222-2222-2222-2222-222222222222"
        let env = sb.env(["SESSIONHOPPER_SESSION_ID": sid])
        let f = env.paths.session(sid)
        let stop = #"{"hook_event_name":"Stop","session_id":"\#(sid)","session_crons":[{"id":"c1","schedule":"7 10 * * *","recurring":true,"prompt":"check   the branch"}]}"#
        _ = HookHandler.handle(input: Data(stop.utf8), env: env, installedProfile: nil)
        XCTAssertEqual(FileIO.readString(f.crons), "7 10 * * * (recurring) - check the branch\n")
        _ = HookHandler.handle(input: Data(#"{"hook_event_name":"Stop","session_id":"\#(sid)","session_crons":[]}"#.utf8), env: env, installedProfile: nil)
        XCTAssertFalse(FileIO.exists(f.crons))
    }

    func testClaudeVersionGate() {
        XCTAssertEqual(Doctor.atLeast("2.1.300 (Claude Code)", Doctor.minClaude), true)
        XCTAssertEqual(Doctor.atLeast("2.1.145", Doctor.minClaude), true)
        XCTAssertEqual(Doctor.atLeast("2.1.99 (Claude Code)", Doctor.minClaude), false)
        XCTAssertNil(Doctor.atLeast("dev build", Doctor.minClaude))
    }

    func testUnsupervisedSessions() {
        let ps = """
              1     0 /sbin/launchd
            100     1 -/bin/zsh
            101   100 /opt/homebrew/bin/sessionhopper --resume abc
            102   101 /Users/me/.local/bin/claude --resume abc --settings {"hooks":{}}
            200     1 -/bin/zsh
            201   200 /Users/me/.local/bin/claude --dangerously-skip-permissions fix mcp server
            202   201 /Users/me/.local/bin/claude -p summarize
            300   200 /Users/me/.local/share/claude/versions/2.1.300 mcp serve
            301   200 claude -p hello
            400   200 bash /Users/me/bin/other-wrapper
            401   400 /Users/me/.local/share/claude/versions/2.1.300 --continue
            """
        XCTAssertEqual(Doctor.unsupervised(ps: ps), [201, 401])
    }
}
