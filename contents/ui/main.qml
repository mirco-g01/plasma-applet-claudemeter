import QtQuick
import QtQuick.Layouts

import org.kde.kirigami as Kirigami
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasma5support as Plasma5Support

PlasmoidItem {
    id: root

    // --- Usage data properties ---
    property real fiveHourUtil: 0
    property string fiveHourResets: ""
    property real sevenDayUtil: 0
    property string sevenDayResets: ""
    // Scoped weekly limits, discovered dynamically from the API's `limits` array
    // (or the legacy `seven_day_*` fields it replaced), so a new plan tier shows
    // up without an update. Each entry: { key, name, label, util, resets }.
    property var weeklyModels: []
    property bool hasError: false
    property string errorMessage: ""
    property bool loading: true
    property date lastUpdated: new Date(0)

    // --- Extra usage ---
    property bool hasExtraUsage: false
    property bool extraUsageEnabled: false
    property real extraUsageUtil: 0
    property string extraUsageLimit: ""
    property string extraUsageUsed: ""
    property string extraUsageDisabledReason: ""

    // --- Limit reset (the API's `cedar_ember` block) ---
    // The grant the server wants spent next, or null. Each: { id, label,
    // resetsLeft, resetsTotal, endsAt, clears, usableNow, requiresLimit,
    // paused, percentUsed }.
    property var resetGrant: null
    property bool resetAtLimit: false
    property bool claimInFlight: false
    // Kept across a failed or unconfirmed claim so a retry reuses it: the server
    // dedupes on it, so a retry can never spend a second reset.
    property string claimRequestId: ""
    property string claimRequestGrant: ""
    property string claimMessage: ""
    property bool claimSucceeded: false

    // --- Cache state ---
    property bool dataCached: false

    // --- Clock ---
    // Ticks so the countdowns and the pace marker keep up between polls: polls are
    // 15 minutes apart and resets_at does not change within a window, so before
    // this existed no binding on formatResetTime ever re-evaluated.
    property date now: new Date()

    readonly property int sessionWindowMs: 5 * 60 * 60 * 1000
    readonly property int weeklyWindowMs: 7 * 24 * 60 * 60 * 1000

    // --- Activity monitor state ---
    property real lastActivityMtime: 0

    // --- Rate limiting ---
    property real lastFetchTime: 0
    property int cooldownMs: 60000
    property int backoffMultiplier: 1
    property int maxBackoffMultiplier: 8
    property bool fetchInFlight: false
    // When the last window-end refetch started, so a payload that still carries
    // a past resets_at does not set off another one on every clock tick.
    property real lastWindowEndFetch: 0
    // Minimum gap between window-end refetches, in case the API keeps answering
    // an ended window with a fresh resets_at.
    property int windowEndGapMs: 300000

    // --- Config ---
    readonly property int pollInterval: plasmoid.configuration.pollInterval * 1000
    readonly property int activityCheckInterval: plasmoid.configuration.activityCheckInterval * 1000
    readonly property int warningThreshold: plasmoid.configuration.warningThreshold
    readonly property int criticalThreshold: plasmoid.configuration.criticalThreshold
    readonly property string claudeFolder: plasmoid.configuration.claudeFolder

    // --- Compact gauge computed properties ---
    readonly property string compactMetric: plasmoid.configuration.compactMetric
    // Picks the most-utilized active model-specific weekly, or an empty stub.
    readonly property var topWeeklyModel: {
        var top = { util: 0, resets: "" }
        for (var i = 0; i < weeklyModels.length; i++) {
            if (weeklyModels[i].util > top.util) top = weeklyModels[i]
        }
        return top
    }
    // Anything unrecognised, including a config value left over from an older
    // release, falls back to the 5-hour window.
    readonly property string outerMetric: (compactMetric === "seven_day" || compactMetric === "model_weekly")
        ? compactMetric : "five_hour"
    readonly property real compactUtil: metricUtil(outerMetric)
    readonly property string compactResets: metricResets(outerMetric)
    readonly property color compactColor: usageColor(compactUtil)

    // --- Inner gauge ring ---
    readonly property string innerMetric: plasmoid.configuration.gaugeInnerMetric
    readonly property real innerUtil: metricUtil(innerMetric)
    readonly property string innerResets: metricResets(innerMetric)
    readonly property color innerColor: usageColor(innerUtil)
    // Nothing to gain from drawing the same number twice, and the default metric
    // only exists for accounts that actually have a scoped weekly limit.
    readonly property bool hasInnerRing: innerMetric !== "none"
        && innerMetric !== outerMetric
        && metricHasData(innerMetric)

    // Metric resolution shared by both gauge rings.
    function metricUtil(metric) {
        if (metric === "five_hour") return fiveHourUtil
        if (metric === "seven_day") return sevenDayUtil
        if (metric === "model_weekly") return topWeeklyModel.util
        return 0
    }

    function metricResets(metric) {
        if (metric === "five_hour") return fiveHourResets
        if (metric === "seven_day") return sevenDayResets
        if (metric === "model_weekly") return topWeeklyModel.resets
        return ""
    }

    function metricHasData(metric) {
        return metricUtil(metric) > 0 || metricResets(metric) !== ""
    }

    // --- Executable DataSource ---
    Plasma5Support.DataSource {
        id: executable
        engine: "executable"
        connectedSources: []
        onNewData: (sourceName, data) => {
            var stdout = data["stdout"]
            root.parseUsageData(stdout)
            disconnectSource(sourceName)
        }
        function exec(cmd) {
            if (cmd) connectSource(cmd)
        }
    }

    // The fetch script is what decides which Claude folder to read, so the
    // activity check runs through it too — otherwise an auto-detected folder
    // would fetch fine but never notice a new session.
    function usageCommand(activity) {
        return root.scriptCommand(activity ? ["--activity"] : [])
    }

    // `args` must be shell-safe as is: the claim ids are regex-checked first.
    function scriptCommand(args) {
        var scriptPath = decodeURIComponent(Qt.resolvedUrl("../scripts/fetch_usage.sh").toString().replace(/^file:\/\//, ""))
        var cmd = "bash \"" + scriptPath + "\""
        for (var i = 0; i < args.length; i++) cmd += " \"" + args[i] + "\""
        var folder = root.claudeFolder.trim()
        if (folder) cmd += " \"" + folder + "\""
        return cmd
    }

    function fetchUsage() {
        root.fetchInFlight = true
        root.loading = true
        root.lastFetchTime = Date.now()
        fetchTimeoutTimer.restart()
        executable.exec(root.usageCommand(false))
    }

    // Returns whether a fetch was started.
    function requestFetch(source) {
        if (root.fetchInFlight) return false

        var bypass = (source === "startup" || source === "manual")
        if (!bypass) {
            var elapsed = Date.now() - root.lastFetchTime
            if (elapsed < root.cooldownMs * root.backoffMultiplier) return false
        }

        pollTimer.restart()
        root.fetchUsage()
        return true
    }

    // Refetches once a window the last payload knows about has ended, so the
    // widget does not sit on "expired" until the next poll (15 minutes by
    // default). Runs off the clock tick rather than a timer set for resets_at,
    // which would fire late after a suspend.
    function checkWindowEnds() {
        var nowMs = root.now.getTime()
        if (nowMs - root.lastWindowEndFetch < root.windowEndGapMs) return
        var resets = [root.fiveHourResets, root.sevenDayResets]
        for (var i = 0; i < root.weeklyModels.length; i++) resets.push(root.weeklyModels[i].resets)
        for (var j = 0; j < resets.length; j++) {
            if (!resets[j]) continue
            var end = new Date(resets[j]).getTime()
            // Written so an unparseable date (NaN fails every comparison) is skipped
            if (!(end <= nowMs && end > root.lastWindowEndFetch)) continue
            // Marked only once a fetch starts: one held back by the cooldown or
            // an in-flight fetch is tried again on the next tick.
            if (root.requestFetch("window_end")) root.lastWindowEndFetch = nowMs
            return
        }
    }

    function parseUsageData(stdout) {
        fetchTimeoutTimer.stop()
        root.fetchInFlight = false
        root.loading = false
        try {
            var data = JSON.parse(stdout)
            if (data.error) {
                root.hasError = true
                root.errorMessage = data.message || data.error
                // A window-end refetch right after a resume often beats the
                // network back; let the next tick try again.
                if (data.error === "network_error") root.lastWindowEndFetch = 0
                return
            }
            root.hasError = false
            root.errorMessage = ""

            var limits = Array.isArray(data.limits) ? data.limits : []

            // The fixed windows have their own top-level fields and are also
            // listed in `limits`. The dedicated fields keep float precision
            // (`limits[].percent` is a rounded int) so they win where present,
            // and `limits` only stands in if one of them goes away.
            var sessionLimit = root.findLimit(limits, "session")
            var weeklyAllLimit = root.findLimit(limits, "weekly_all")
            if (data.five_hour) {
                root.fiveHourUtil = data.five_hour.utilization || 0
                root.fiveHourResets = data.five_hour.resets_at || ""
            } else if (sessionLimit) {
                root.fiveHourUtil = sessionLimit.percent || 0
                root.fiveHourResets = sessionLimit.resets_at || ""
            }
            if (data.seven_day) {
                root.sevenDayUtil = data.seven_day.utilization || 0
                root.sevenDayResets = data.seven_day.resets_at || ""
            } else if (weeklyAllLimit) {
                root.sevenDayUtil = weeklyAllLimit.percent || 0
                root.sevenDayResets = weeklyAllLimit.resets_at || ""
            }

            var weeklies = []
            var seenKeys = {}

            // Every weekly that is not the all-models one is a scoped limit:
            // per model today (Fable), possibly per surface tomorrow.
            for (var i = 0; i < limits.length; i++) {
                var limit = limits[i]
                if (!limit || limit.group !== "weekly" || limit.kind === "weekly_all") continue
                // Deliberately not filtered on `is_active`: the API sets it on
                // the scoped entry while leaving it false on both fixed windows,
                // so it does not mean "this limit is live".
                var scopeName = root.scopeNameFor(limit.scope)
                var scopeUtil = limit.percent || 0
                var scopeResets = limit.resets_at || ""
                if (scopeUtil <= 0 && !scopeResets) continue
                var scopeKey = root.scopedKeyFor(scopeName)
                seenKeys[scopeKey] = true
                weeklies.push({
                    key: scopeKey,
                    name: scopeName,
                    // The API already supplies the right casing, so the label is
                    // built from the display name rather than from the key.
                    label: "Weekly (" + scopeName + ")",
                    util: scopeUtil,
                    resets: scopeResets
                })
            }

            // Legacy per-model fields, all null since 2026-08 but cheap to keep
            // reading in case the shape moves again.
            for (var key in data) {
                if (key === "seven_day" || key.indexOf("seven_day_") !== 0) continue
                if (seenKeys[key]) continue
                var entry = data[key]
                if (!entry) continue
                var util = entry.utilization || 0
                var resets = entry.resets_at || ""
                if (util <= 0 && !resets) continue
                seenKeys[key] = true
                weeklies.push({
                    key: key,
                    name: root.weeklyNameFor(key),
                    label: root.weeklyLabelFor(key),
                    util: util,
                    resets: resets
                })
            }
            weeklies.sort(function (a, b) {
                if (b.util !== a.util) return b.util - a.util
                return a.key < b.key ? -1 : a.key > b.key ? 1 : 0
            })
            root.weeklyModels = weeklies

            if (data.extra_usage) {
                root.hasExtraUsage = true
                root.extraUsageEnabled = data.extra_usage.is_enabled || false
                root.extraUsageUtil = data.extra_usage.utilization || 0
                root.extraUsageLimit = data.extra_usage.monthly_limit != null ? plasmoid.configuration.currencySymbol + (data.extra_usage.monthly_limit / 100).toFixed(2) : ""
                root.extraUsageUsed = plasmoid.configuration.currencySymbol + ((data.extra_usage.used_credits || 0) / 100).toFixed(2)
                root.extraUsageDisabledReason = data.extra_usage.disabled_reason || ""
            } else {
                root.hasExtraUsage = false
                root.extraUsageEnabled = false
                root.extraUsageDisabledReason = ""
            }

            root.resetGrant = root.parseResetGrant(data.cedar_ember)
            root.resetAtLimit = !!(data.cedar_ember && data.cedar_ember.at_limit)

            root.dataCached = !!data.cached
            if (data.rate_limited) {
                root.backoffMultiplier = Math.min(root.backoffMultiplier * 2, root.maxBackoffMultiplier)
            } else {
                root.backoffMultiplier = 1
            }

            if (data.cached && data._fetched_at) {
                root.lastUpdated = new Date(data._fetched_at * 1000)
            } else {
                root.lastUpdated = new Date()
            }
        } catch (e) {
            root.hasError = true
            root.errorMessage = "Failed to parse response"
        }
    }

    // --- Helper functions ---
    function weeklyNameFor(key) {
        var suffix = key.replace(/^seven_day_/, "")
        var parts = suffix.split("_")
        for (var i = 0; i < parts.length; i++) {
            parts[i] = parts[i].charAt(0).toUpperCase() + parts[i].slice(1)
        }
        return parts.join(" ")
    }

    function weeklyLabelFor(key) {
        return "Weekly (" + root.weeklyNameFor(key) + ")"
    }

    // Canonical key for a scoped limit, so `limits` entries dedupe against
    // legacy `seven_day_*` keys and sort with the same tiebreak.
    function scopedKeyFor(displayName) {
        return "seven_day_" + displayName.toLowerCase().replace(/[^a-z0-9]+/g, "_")
    }

    // What to call a scoped limit. `surface` comes as a bare string in some
    // responses and as an object shaped like `model` in others.
    function scopeNameFor(scope) {
        if (scope) {
            if (scope.model) {
                if (scope.model.display_name) return scope.model.display_name
                if (scope.model.id) return scope.model.id
            }
            if (scope.surface) {
                if (typeof scope.surface === "string") return scope.surface
                if (scope.surface.display_name) return scope.surface.display_name
                if (scope.surface.id) return scope.surface.id
            }
        }
        return "Scoped"
    }

    // The grant to offer from a `cedar_ember` block, or null. Only the one the
    // server names as next is offered: it rejects a claim on any other.
    function parseResetGrant(block) {
        if (!block || !block.eligible || !Array.isArray(block.grants)) return null
        for (var i = 0; i < block.grants.length; i++) {
            var g = block.grants[i]
            if (!g || g.id !== block.next_grant_id) continue
            if (!/^[a-z0-9_-]{1,40}$/.test(g.id) || !(g.resets_left > 0)) return null
            return {
                id: g.id,
                label: g.label || "",
                resetsLeft: g.resets_left,
                resetsTotal: g.resets_total || g.resets_left,
                endsAt: g.ends_at || "",
                clears: Array.isArray(g.clears) ? g.clears : [],
                usableNow: !!g.usable_now,
                requiresLimit: g.use_requires_limit !== false,
                paused: !!g.paused,
                percentUsed: g.percent_used || {}
            }
        }
        return null
    }

    // What a limit key in a grant's `clears` list is called in the popup.
    function limitNameFor(key) {
        if (key === "five_hour") return "5-hour"
        if (key === "seven_day") return "weekly"
        // The scoped weeklies: its percent_used tracks the Fable bar exactly.
        if (key === "seven_day_overage_included") {
            var names = []
            for (var i = 0; i < root.weeklyModels.length; i++) names.push(root.weeklyModels[i].name)
            return names.length ? names.join(", ") + " weekly" : "model weekly"
        }
        return root.weeklyNameFor(key) + " weekly"
    }

    function resetClearsText(grant) {
        if (!grant) return ""
        var names = []
        for (var i = 0; i < grant.clears.length; i++) names.push(root.limitNameFor(grant.clears[i]))
        if (names.length === 0) return "your limits"
        if (names.length === 1) return names[0]
        return names.slice(0, -1).join(", ") + " and " + names[names.length - 1]
    }

    // "You still have 67% of your Fable weekly limit left.", about the fullest
    // limit the reset would clear, or "" when that is unknown.
    function resetEarlyText(grant) {
        if (!grant) return ""
        var topKey = "", topPct = -1
        for (var i = 0; i < grant.clears.length; i++) {
            var pct = grant.percentUsed[grant.clears[i]]
            if (typeof pct === "number" && pct > topPct) {
                topPct = pct
                topKey = grant.clears[i]
            }
        }
        if (topPct < 0 || topPct >= 100) return ""
        return "You still have " + (100 - topPct) + "% of your " + root.limitNameFor(topKey) + " limit left."
    }

    function newRequestId() {
        var hex = ""
        for (var i = 0; i < 32; i++) hex += Math.floor(Math.random() * 16).toString(16)
        return hex
    }

    // Spends one reset. Only ever called from the popup's confirm button.
    function claimReset() {
        var grant = root.resetGrant
        if (!grant || root.claimInFlight) return
        if (root.claimRequestGrant !== grant.id || !root.claimRequestId) {
            root.claimRequestId = root.newRequestId()
            root.claimRequestGrant = grant.id
        }
        root.claimInFlight = true
        root.claimMessage = ""
        root.claimSucceeded = false
        claimRunner.command = root.scriptCommand(["--claim", grant.id, root.claimRequestId])
        claimTimeoutTimer.restart()
        claimRunner.connectSource(claimRunner.command)
    }

    function handleClaimResult(stdout) {
        claimTimeoutTimer.stop()
        root.claimInFlight = false
        var data
        try {
            data = JSON.parse(stdout)
        } catch (e) {
            data = { claim: { result: "error" } }
        }
        if (data.error) {
            // Stopped before anything was sent (no token, no organization).
            root.claimRequestId = ""
            root.claimMessage = data.message || data.error
            return
        }
        var claim = data.claim || { result: "error" }
        root.claimSucceeded = claim.result === "reset"
        root.claimMessage = root.claimMessageFor(claim)
        // An unconfirmed claim keeps its id, so trying again cannot double-spend.
        if (claim.result !== "error") root.claimRequestId = ""
        claimRefreshTimer.restart()
    }

    function claimMessageFor(claim) {
        switch (claim.result) {
        case "reset":
            var left = typeof claim.resets_left === "number" ? " · " + claim.resets_left + " left" : ""
            return "Limits reset" + left
        case "already_used":
            return "That reset was already used · nothing changed just now"
        case "not_limited":
            return "This reset only works at a usage limit, and you're not at one now · nothing was used"
        case "cooldown":
            return "Another reset was just started on your account · try again in a minute"
        case "ineligible":
            return "This reset isn't available any more · nothing was used"
        case "unavailable":
            return "Couldn't reset your limits · nothing was used · try again in a moment"
        case "rate_limited":
            return "Too many requests · nothing was used · try again in a moment"
        case "auth_error":
            return "Couldn't reset your limits with this login · run claude and /login, then try again"
        case "dry_run":
            return "Dry run · nothing was sent"
        default:
            return "Couldn't confirm the reset went through · if the bars don't drop after the refresh, try again"
        }
    }

    // First entry in the API's `limits` array of the given kind, or null.
    function findLimit(limits, kind) {
        for (var i = 0; i < limits.length; i++) {
            if (limits[i] && limits[i].kind === kind) return limits[i]
        }
        return null
    }

    function usageColor(percent) {
        if (percent >= root.criticalThreshold) {
            return Kirigami.Theme.negativeTextColor
        } else if (percent >= root.warningThreshold) {
            return plasmoid.configuration.warningColor || "#E5C07B"
        } else {
            return plasmoid.configuration.normalColor || "#D77757"
        }
    }

    function formatResetTime(isoString) {
        if (!isoString) return ""
        var d = new Date(isoString)
        var now = root.now
        var diffMs = d.getTime() - now.getTime()
        if (diffMs <= 0) return "expired"
        var diffMin = Math.floor(diffMs / 60000)
        var diffHrs = Math.floor(diffMin / 60)
        var remainMin = diffMin % 60
        if (diffHrs >= 24) {
            var days = Math.floor(diffHrs / 24)
            var hrs = diffHrs % 24
            return days + "d " + hrs + "h"
        }
        if (diffHrs > 0) return diffHrs + "h " + remainMin + "m"
        return diffMin + "m"
    }

    // Fraction 0..1 of a window that has elapsed, or -1 when it cannot be known.
    // The API sends no window start, but both windows are a fixed length, so the
    // start is resets_at minus that length.
    function paceFraction(resetsAt, windowMs) {
        if (!resetsAt || !windowMs) return -1
        var end = new Date(resetsAt).getTime()
        if (isNaN(end)) return -1
        var elapsed = windowMs - (end - root.now.getTime())
        // Unknown, rather than pinned to an edge: over a window elapsed means the
        // reset is already past (stale payload, or no session in the last 5h), and
        // under zero means it is more than a whole window out (clock skew).
        if (elapsed < 0 || elapsed > windowMs) return -1
        return elapsed / windowMs
    }

    // --- Activity monitor DataSource ---
    Plasma5Support.DataSource {
        id: activityChecker
        engine: "executable"
        connectedSources: []
        onNewData: (sourceName, data) => {
            var stdout = data["stdout"].trim()
            var mtime = parseInt(stdout)
            if (!isNaN(mtime)) {
                if (root.lastActivityMtime > 0 && mtime > root.lastActivityMtime) {
                    fetchDelayTimer.restart()
                }
                root.lastActivityMtime = mtime
            }
            disconnectSource(sourceName)
        }
        function check() {
            connectSource(root.usageCommand(true))
        }
    }

    // --- Activity check timer ---
    Timer {
        id: activityTimer
        interval: root.activityCheckInterval
        running: true
        repeat: true
        onTriggered: activityChecker.check()
        Component.onCompleted: activityChecker.check()
    }

    // --- Fetch timeout recovery ---
    Timer {
        id: fetchTimeoutTimer
        interval: 30000
        running: false
        repeat: false
        onTriggered: {
            executable.disconnectSource(root.usageCommand(false))
            root.fetchInFlight = false
            root.loading = false
            root.hasError = true
            root.errorMessage = "Request timed out"
        }
    }

    // --- Limit reset claim ---
    Plasma5Support.DataSource {
        id: claimRunner
        property string command: ""
        engine: "executable"
        connectedSources: []
        onNewData: (sourceName, data) => {
            disconnectSource(sourceName)
            root.handleClaimResult(data["stdout"])
        }
    }

    // curl gives up after 25s; this only fires if the script itself hangs.
    Timer {
        id: claimTimeoutTimer
        interval: 40000
        running: false
        repeat: false
        onTriggered: {
            claimRunner.disconnectSource(claimRunner.command)
            root.handleClaimResult("")
        }
    }

    // Re-read usage once the server has applied the reset, so the bars and the
    // remaining count come from it rather than from the claim response.
    Timer {
        id: claimRefreshTimer
        interval: 2000
        running: false
        repeat: false
        onTriggered: root.requestFetch("manual")
    }

    // A stale confirmation or result would be confusing the next time the popup opens.
    onExpandedChanged: {
        if (!root.expanded && !root.claimInFlight) root.claimMessage = ""
    }

    // --- Delay before fetching after activity ---
    Timer {
        id: fetchDelayTimer
        interval: 15000
        running: false
        repeat: false
        onTriggered: root.requestFetch("activity")
    }

    // --- Clock tick ---
    // 30s is well under 1% of a 5-hour window and costs one date assignment.
    Timer {
        id: clockTimer
        interval: 30000
        running: true
        repeat: true
        onTriggered: {
            root.now = new Date()
            root.checkWindowEnds()
        }
    }

    // --- Polling timer ---
    Timer {
        id: pollTimer
        interval: root.pollInterval
        running: true
        repeat: true
        onTriggered: root.requestFetch("poll")
        Component.onCompleted: {
            // The startup fetch is fresh already. Counting it as a window-end
            // refetch keeps an old cached payload (served when it is rate
            // limited) from setting off another request a tick later.
            root.lastWindowEndFetch = Date.now()
            root.requestFetch("startup")
        }
    }

    // --- Widget setup ---
    switchWidth: Kirigami.Units.gridUnit * 12
    switchHeight: Kirigami.Units.gridUnit * 8

    compactRepresentation: CompactRepresentation {}
    fullRepresentation: FullRepresentation {}
}
