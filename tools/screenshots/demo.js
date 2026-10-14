.pragma library
// Demo payloads in the usage endpoint's shape. Times are set against the
// moment of rendering, so pace markers and countdowns land where a shot needs them.

var HOUR = 3600000
var FIVE_HOURS = 5 * HOUR
var WEEK = 7 * 24 * HOUR

// When a window that is `elapsed` (0..1) through ends.
function resetsAt(now, windowMs, elapsed) {
    return new Date(now + windowMs * (1 - elapsed)).toISOString()
}

// o.session and o.weekly: [percent used, fraction of the window elapsed].
// o.scoped: [[model name, percent used], ...], sharing the weekly window.
// o.extra: [dollars used, monthly limit in dollars]. o.reset: offer a limit reset.
function payload(o, now) {
    var weeklyEnd = resetsAt(now, WEEK, o.weekly[1])
    var data = {
        five_hour: { utilization: o.session[0], resets_at: resetsAt(now, FIVE_HOURS, o.session[1]) },
        seven_day: { utilization: o.weekly[0], resets_at: weeklyEnd },
        limits: []
    }
    var scoped = o.scoped || []
    for (var i = 0; i < scoped.length; i++) {
        data.limits.push({
            group: "weekly", kind: "weekly_scoped", is_active: true,
            percent: scoped[i][1], resets_at: weeklyEnd,
            scope: { model: { display_name: scoped[i][0] } }
        })
    }
    if (o.extra) {
        data.extra_usage = {
            is_enabled: true,
            used_credits: o.extra[0] * 100,
            monthly_limit: o.extra[1] * 100,
            utilization: o.extra[0] / o.extra[1] * 100
        }
    }
    if (o.reset) {
        data.cedar_ember = {
            eligible: true, at_limit: false, next_grant_id: "demo",
            grants: [{
                id: "demo", label: "", resets_left: 1, resets_total: 1,
                ends_at: new Date(now + 9 * 24 * HOUR).toISOString(),
                clears: ["five_hour", "seven_day", "seven_day_overage_included"],
                usable_now: true, use_requires_limit: true, paused: false,
                percent_used: { five_hour: o.session[0], seven_day: o.weekly[0] }
            }]
        }
    }
    return JSON.stringify(data)
}

// The main account in every shot: calm 5-hour, weekly a little ahead of
// pace, the scoped weekly in the warning band and ahead too.
var max = {
    session: [38, 0.62],
    weekly: [55, 0.43],
    scoped: [["Fable", 84]],
    extra: [13.51, 50],
    reset: true
}

// A second, lightly used account.
var pro = {
    session: [12, 0.2],
    weekly: [27, 0.5],
    scoped: [["Fable", 9]]
}

// Everything under the warning threshold, so a custom colour fills every bar.
var mid = {
    session: [46, 0.5],
    weekly: [63, 0.7],
    scoped: [["Fable", 52]]
}

var critical = {
    session: [97, 0.7],
    weekly: [71, 0.6],
    scoped: [["Fable", 88]]
}
