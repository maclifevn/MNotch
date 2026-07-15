import Foundation
import XCTest
@testable import MNotch

final class CoreLogicTests: XCTestCase {
    func testDisablingEveryCalendarProducesNoEnabledSource() {
        let available = ["work", "personal"]
        let enabled = CalendarSourceSelection.enabledIdentifiers(
            available: available,
            disabled: available
        )
        XCTAssertTrue(enabled.isEmpty)
    }

    func testCalendarSelectionPreservesAvailableOrder() {
        XCTAssertEqual(
            CalendarSourceSelection.enabledIdentifiers(
                available: ["work", "personal", "birthdays"],
                disabled: ["personal"]
            ),
            ["work", "birthdays"]
        )
    }

    func testUnknownAgentDecisionFallsBackToAsk() {
        XCTAssertEqual(AgentDecision.normalized("unexpected"), .ask)
        XCTAssertEqual(AgentDecision.normalized("allow"), .allow)
        XCTAssertEqual(AgentDecision.normalized("deny"), .deny)
    }

    func testCodexPermissionResponseMatchesAllowDenySchema() throws {
        for decision in [AgentDecision.allow, .deny] {
            let data = try XCTUnwrap(AgentHookResponse.data(
                event: "PermissionRequest",
                decision: decision
            ))
            let root = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            let output = try XCTUnwrap(root["hookSpecificOutput"] as? [String: Any])
            XCTAssertEqual(output["hookEventName"] as? String, "PermissionRequest")
            let payload = try XCTUnwrap(output["decision"] as? [String: Any])
            XCTAssertEqual(payload["behavior"] as? String, decision.rawValue)
        }
        XCTAssertNil(AgentHookResponse.data(event: "PermissionRequest", decision: .ask))
    }

    func testAppleScriptSessionIdentifierRejectsInjection() {
        XCTAssertEqual(
            AgentMonitorService.safeAppleScriptIdentifier("w0t0p0:ABC-123"),
            "w0t0p0:ABC-123"
        )
        XCTAssertNil(AgentMonitorService.safeAppleScriptIdentifier("x\" then do shell script"))
    }

    @MainActor
    func testAskUserQuestionIsNotApprovableFromNotch() {
        // Interactive-UI tools must never surface as a notch Allow/Deny card.
        XCTAssertFalse(AgentMonitorService.canApproveFromNotch("AskUserQuestion"))
        XCTAssertTrue(AgentMonitorService.canApproveFromNotch("Edit"))
        XCTAssertTrue(AgentMonitorService.canApproveFromNotch("Bash"))
        XCTAssertTrue(AgentMonitorService.canApproveFromNotch(nil))
    }

    @MainActor
    func testTerminalBundleIDMapsKnownProgramsForFrontmostCheck() {
        XCTAssertEqual(AgentMonitorService.terminalBundleID("iTerm.app"), "com.googlecode.iterm2")
        XCTAssertEqual(AgentMonitorService.terminalBundleID("Apple_Terminal"), "com.apple.Terminal")
        XCTAssertEqual(AgentMonitorService.terminalBundleID("ghostty"), "com.mitchellh.ghostty")
        // Unknown or missing terminals can't be matched, so the notch is shown
        // rather than wrongly deferred to a terminal we can't identify.
        XCTAssertNil(AgentMonitorService.terminalBundleID("some-unknown-term"))
        XCTAssertNil(AgentMonitorService.terminalBundleID(nil))
    }

    func testDeferDecisionProducesNoPermissionOutput() {
        // Deferring to the terminal replies "ask"; for PermissionRequest that
        // means no output, so the agent falls back to its native prompt.
        XCTAssertNil(AgentHookResponse.data(event: "PermissionRequest", decision: .ask))
    }

    func testClaudeCLIUsageParsesSessionAndWeeklyWindows() throws {
        let output = """
        You are currently using your subscription to power your Claude Code usage

        Current session: 4% used · resets Jul 15 at 6:30pm (Asia/Saigon)
        Current week (all models): 74% used · resets Jul 17 at 8pm (Asia/Saigon)
        Current week (Fable): 57% used · resets Jul 17 at 8pm (Asia/Saigon)

        What's contributing to your limits usage?
        Last 24h · 540 requests · 3 sessions
        """
        let windows = try XCTUnwrap(ClaudeUsageClient.parse(output))
        XCTAssertEqual(windows.map(\.label), ["5h", "7d", "Fable"])
        XCTAssertEqual(windows.map(\.id), ["claude-session", "claude-week", "claude-week-Fable"])
        XCTAssertEqual(windows[0].usedPercent, 4)
        XCTAssertEqual(windows[1].usedPercent, 74)
        XCTAssertEqual(windows[2].usedPercent, 57)
        XCTAssertEqual(windows[0].durationMinutes, 300)
        XCTAssertEqual(windows[1].durationMinutes, 10_080)
        XCTAssertNotNil(windows[0].resetsAt)
    }

    func testClaudeCLIUsageIgnoresProseAndReturnsNilWhenNoBars() {
        let output = """
        Approximate, based on local sessions on this machine.
        66% of your usage came from subagent-heavy sessions
        Top subagents: workflow-subagent 11%
        """
        XCTAssertNil(ClaudeUsageClient.parse(output))
    }

    func testClaudeCLIResetDateParsesDatedForm() {
        let date = ClaudeUsageClient.parseCLIDate("resets Jul 17 at 8pm (Asia/Saigon)")
        XCTAssertNotNil(date)
    }

    func testClaudeCLIUsageParsesLineWithLongTimezoneAndOverage() throws {
        // A long IANA timezone at 100% used pushes the line past 90 chars; it
        // must still parse (the old guard dropped it).
        let output = """
        Current week (all models): 100% used · resets Dec 31 at 11:59pm (America/Argentina/Buenos_Aires)
        """
        let windows = try XCTUnwrap(ClaudeUsageClient.parse(output))
        XCTAssertEqual(windows.map(\.label), ["7d"])
        XCTAssertEqual(windows[0].usedPercent, 100)
    }

    func testQuotaParserCountsBillableFieldsOnly() throws {
        let json = #"{"timestamp":"2026-07-14T10:00:00.000Z","message":{"usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":3,"cache_read_input_tokens":1000}}}"#
        let result = QuotaUsageParser.fields(from: try XCTUnwrap(json.data(using: .utf8)))
        XCTAssertEqual(result?.timestamp, "2026-07-14T10:00:00.000Z")
        XCTAssertEqual(result?.tokens, 18)
    }

    func testQuotaParserRejectsLinesWithoutUsage() throws {
        let data = try XCTUnwrap(#"{"timestamp":"2026-07-14T10:00:00Z"}"#.data(using: .utf8))
        XCTAssertNil(QuotaUsageParser.fields(from: data))
    }

    func testCodexQuotaParserReadsOfficialWindowsAndCredits() throws {
        let json = #"{"id":2,"result":{"rateLimits":{"planType":"plus","credits":{"balance":"12.50"},"primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":1784044800},"secondary":{"usedPercent":60,"windowDurationMins":10080,"resetsAt":1784649600}},"rateLimitResetCredits":{"availableCount":2}}}"#
        let snapshot = try XCTUnwrap(CodexQuotaParser.snapshot(
            from: try XCTUnwrap(json.data(using: .utf8))
        ))
        XCTAssertEqual(snapshot.planType, "plus")
        XCTAssertEqual(snapshot.creditsBalance, "12.50")
        XCTAssertEqual(snapshot.resetCredits, 2)
        XCTAssertEqual(snapshot.primary?.label, "5h")
        XCTAssertEqual(snapshot.primary?.remainingPercent, 75)
        XCTAssertEqual(snapshot.secondary?.label, "7d")
        XCTAssertEqual(snapshot.secondary?.remainingPercent, 40)
    }

    func testCodexSparseUpdateKeepsWindowMetadata() throws {
        let initialJSON = #"{"id":2,"result":{"rateLimits":{"planType":"plus","primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":1784044800}},"rateLimitResetCredits":{"availableCount":2}}}"#
        let updateJSON = #"{"method":"account/rateLimits/updated","params":{"rateLimits":{"primary":{"usedPercent":31}}}}"#
        let initial = try XCTUnwrap(CodexQuotaParser.snapshot(
            from: try XCTUnwrap(initialJSON.data(using: .utf8))
        ))
        let update = try XCTUnwrap(CodexQuotaParser.snapshot(
            from: try XCTUnwrap(updateJSON.data(using: .utf8))
        ))
        let merged = update.merging(over: initial)

        XCTAssertEqual(merged.primary?.label, "5h")
        XCTAssertEqual(merged.primary?.durationMinutes, 300)
        XCTAssertEqual(merged.primary?.resetsAt, initial.primary?.resetsAt)
        XCTAssertEqual(merged.primary?.usedPercent, 31)
        XCTAssertEqual(merged.planType, "plus")
        XCTAssertEqual(merged.resetCredits, 2)
    }

    func testCodexIndividualBudgetIsUsedWhenRollingWindowsAreAbsent() throws {
        let json = #"{"id":2,"result":{"rateLimits":{"planType":"business","individualLimit":{"limit":"100","used":"58","remainingPercent":42,"resetsAt":1784649600}}}}"#
        let snapshot = try XCTUnwrap(CodexQuotaParser.snapshot(
            from: try XCTUnwrap(json.data(using: .utf8))
        ))

        XCTAssertEqual(snapshot.primary?.label, "Budget")
        XCTAssertEqual(snapshot.primary?.remainingPercent, 42)
        XCTAssertEqual(snapshot.primary?.resetsAt?.timeIntervalSince1970, 1_784_649_600)
    }

    func testClaudeQuotaEventNormalizesFiveHourAndWeeklyWindows() throws {
        let json = #"{"event":"quota","agent_kind":"claude","quota_updated_at":1784044800,"rate_limits":{"five_hour":{"used_percentage":21.5,"resets_at":1784050000},"seven_day":{"used_percentage":64,"resets_at":1784649600}}}"#
        let event = try JSONDecoder().decode(
            AgentEvent.self,
            from: try XCTUnwrap(json.data(using: .utf8))
        )
        let windows = try XCTUnwrap(event.rateLimits).normalizedWindows
        XCTAssertEqual(windows.map(\.label), ["5h", "7d"])
        XCTAssertEqual(windows[0].remainingPercent, 78.5)
        XCTAssertEqual(windows[1].remainingPercent, 36)
        XCTAssertEqual(event.quotaUpdatedAt, 1_784_044_800)
    }

    func testDiffEngineTracksReplacementAndLineNumbers() {
        let result = DiffEngine.rows(old: "one\ntwo\nthree", new: "one\nTWO\nthree")
        XCTAssertEqual(result.adds, 1)
        XCTAssertEqual(result.dels, 1)
        XCTAssertEqual(result.rows.map(\.kind), [.equal, .remove, .add, .equal])
        XCTAssertEqual(result.rows.map(\.oldNo), [1, 2, nil, 3])
        XCTAssertEqual(result.rows.map(\.newNo), [1, nil, 2, 3])
    }

    func testDiffEngineUsesBoundedFallbackForLargeInput() {
        let old = Array(repeating: "old", count: 201).joined(separator: "\n")
        let new = Array(repeating: "new", count: 201).joined(separator: "\n")
        let result = DiffEngine.rows(old: old, new: new)
        XCTAssertEqual(result.dels, 201)
        XCTAssertEqual(result.adds, 201)
        XCTAssertEqual(result.rows.count, 402)
    }

    func testIdleResolverDegradesDuoToAvailableContent() {
        XCTAssertEqual(
            NotchIdleResolver.resolve(.init(
                activity: .duo,
                mostRecent: false,
                mediaAvailable: true,
                calendarAvailable: false,
                dismissed: false
            )),
            .playing
        )
    }

    func testIdleResolverHonorsDismissalAndMostRecent() {
        XCTAssertEqual(
            NotchIdleResolver.resolve(.init(
                activity: .calendar,
                mostRecent: true,
                mediaAvailable: true,
                calendarAvailable: true,
                dismissed: false
            )),
            .playing
        )
        XCTAssertEqual(
            NotchIdleResolver.resolve(.init(
                activity: .duo,
                mostRecent: false,
                mediaAvailable: true,
                calendarAvailable: true,
                dismissed: true
            )),
            .empty
        )
    }

    @MainActor
    func testCodexHookInstallerPreservesOtherHandlers() throws {
        let root: [String: Any] = [
            "custom": "keep",
            "hooks": [
                "PermissionRequest": [[
                    "matcher": "Bash",
                    "hooks": [["type": "command", "command": "other-hook"]],
                ]],
            ],
        ]
        let installed = CodexHookInstaller.installing(
            into: root,
            command: "/usr/bin/perl '/tmp/mnotch-relay.pl' codex"
        )
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: installed))
        let hooks = try XCTUnwrap(installed["hooks"] as? [String: Any])
        for event in ["PermissionRequest", "SessionStart", "Stop"] {
            let groups = try XCTUnwrap(hooks[event] as? [[String: Any]])
            XCTAssertTrue(groups.contains { group in
                (group["hooks"] as? [[String: Any]])?.contains { handler in
                    (handler["command"] as? String)?.contains("mnotch-relay.pl") == true
                } == true
            })
        }

        let removed = CodexHookInstaller.uninstalling(from: installed)
        XCTAssertEqual(removed["custom"] as? String, "keep")
        let remainingHooks = try XCTUnwrap(removed["hooks"] as? [String: Any])
        let permissionGroups = try XCTUnwrap(
            remainingHooks["PermissionRequest"] as? [[String: Any]]
        )
        XCTAssertEqual(
            (permissionGroups.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String,
            "other-hook"
        )
        XCTAssertNil(remainingHooks["SessionStart"])
        XCTAssertNil(remainingHooks["Stop"])
    }

    @MainActor
    func testCodexPermissionPayloadDecodesPatchAndLastMessage() throws {
        let json = #"{"event":"PermissionRequest","session_id":"codex-1","cwd":"/tmp/project","tool_name":"apply_patch","tool_input":{"patch":"*** Begin Patch\n*** End Patch"},"last_assistant_message":"Review this change","agent_kind":"codex"}"#
        let event = try JSONDecoder().decode(
            AgentEvent.self,
            from: try XCTUnwrap(json.data(using: .utf8))
        )
        XCTAssertEqual(event.lastMessage, "Review this change")
        XCTAssertEqual(
            AgentMonitorService.detail(event),
            .patch(patch: "*** Begin Patch\n*** End Patch")
        )
    }
}
