import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2

import org.kde.kirigami as Kirigami

// Offers the usage-limit reset the API grants (its `cedar_ember` block), the
// same one claude.ai shows under Settings > Usage. Spending it takes two
// clicks: "Use reset", then an explicit confirmation.
ColumnLayout {
    id: card

    property bool confirming: false

    readonly property var grant: root.resetGrant
    readonly property string grantId: grant ? grant.id : ""
    readonly property bool blockedByLimit: grant !== null && grant.requiresLimit && !root.resetAtLimit
    readonly property bool canUse: grant !== null && grant.usableNow && !grant.paused
        && !card.blockedByLimit && !root.claimInFlight
    readonly property string clearsText: root.resetClearsText(grant)
    readonly property string blockedText: {
        if (!grant || root.claimInFlight) return ""
        if (grant.paused) return "Paused for now"
        if (card.blockedByLimit) return "Usable once you reach a limit"
        if (!grant.usableNow) return "Not usable right now"
        return ""
    }
    readonly property string weeklyResetDay: root.sevenDayResets
        ? Qt.formatDate(new Date(root.sevenDayResets), "dddd") : ""

    visible: grant !== null || root.claimMessage !== ""
    spacing: Kirigami.Units.smallSpacing

    // A different grant, or none, makes a pending confirmation meaningless.
    onGrantIdChanged: card.confirming = false

    Connections {
        target: root
        function onExpandedChanged() {
            if (!root.expanded) card.confirming = false
        }
    }

    Kirigami.Separator { Layout.fillWidth: true }

    RowLayout {
        Layout.fillWidth: true
        spacing: Kirigami.Units.smallSpacing

        Kirigami.Icon {
            source: "chronometer-reset"
            Layout.preferredWidth: Kirigami.Units.iconSizes.small
            Layout.preferredHeight: Kirigami.Units.iconSizes.small
        }
        QQC2.Label {
            text: "Limit reset"
            font.pointSize: Kirigami.Theme.smallFont.pointSize
            font.bold: true
            Layout.fillWidth: true
        }
        QQC2.Label {
            visible: card.grant !== null
            text: card.grant ? card.grant.resetsLeft + " of " + card.grant.resetsTotal + " left" : ""
            font: Kirigami.Theme.smallFont
            color: Kirigami.Theme.disabledTextColor
        }
    }

    QQC2.Label {
        Layout.fillWidth: true
        visible: card.grant !== null && card.grant.label !== ""
        text: card.grant ? card.grant.label : ""
        font: Kirigami.Theme.smallFont
        color: Kirigami.Theme.disabledTextColor
        wrapMode: Text.Wrap
    }

    QQC2.Label {
        Layout.fillWidth: true
        visible: card.grant !== null
        text: {
            if (!card.grant) return ""
            var parts = ["Refills " + card.clearsText]
            if (card.grant.endsAt) parts.push("use by " + Qt.formatDate(new Date(card.grant.endsAt), "MMM d"))
            return parts.join(" · ")
        }
        font: Kirigami.Theme.smallFont
        wrapMode: Text.Wrap
    }

    // Idle: the button, or why it is off.
    RowLayout {
        Layout.fillWidth: true
        visible: card.grant !== null && !card.confirming
        spacing: Kirigami.Units.smallSpacing

        QQC2.Label {
            text: card.blockedText
            font: Kirigami.Theme.smallFont
            color: Kirigami.Theme.disabledTextColor
            wrapMode: Text.Wrap
            Layout.fillWidth: true
        }
        QQC2.Button {
            text: root.claimInFlight ? "Resetting…" : "Use reset"
            icon.name: "chronometer-reset"
            enabled: card.canUse
            onClicked: card.confirming = true
        }
    }

    // Confirmation.
    ColumnLayout {
        Layout.fillWidth: true
        visible: card.grant !== null && card.confirming
        spacing: Kirigami.Units.smallSpacing

        QQC2.Label {
            Layout.fillWidth: true
            text: "Use your reset now? It refills your " + card.clearsText + " limits"
                + (card.weeklyResetDay ? " and your weekly reset day stays " + card.weeklyResetDay : "")
                + ". This can't be undone."
            font: Kirigami.Theme.smallFont
            wrapMode: Text.Wrap
        }
        QQC2.Label {
            Layout.fillWidth: true
            readonly property string early: root.resetAtLimit ? "" : root.resetEarlyText(card.grant)
            visible: early !== ""
            text: early
            font: Kirigami.Theme.smallFont
            color: plasmoid.configuration.warningColor || "#E5C07B"
            wrapMode: Text.Wrap
        }
        RowLayout {
            Layout.fillWidth: true
            spacing: Kirigami.Units.smallSpacing

            Item { Layout.fillWidth: true }
            QQC2.Button {
                text: "Keep it"
                onClicked: card.confirming = false
            }
            QQC2.Button {
                text: "Yes, use my reset"
                enabled: card.canUse
                onClicked: {
                    card.confirming = false
                    root.claimReset()
                }
            }
        }
    }

    QQC2.Label {
        Layout.fillWidth: true
        visible: root.claimMessage !== ""
        text: root.claimMessage
        font: Kirigami.Theme.smallFont
        color: root.claimSucceeded ? Kirigami.Theme.positiveTextColor : Kirigami.Theme.negativeTextColor
        wrapMode: Text.Wrap
    }
}
