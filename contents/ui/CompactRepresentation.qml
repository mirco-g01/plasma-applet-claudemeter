import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2

import org.kde.kirigami as Kirigami

MouseArea {
    id: compactRep

    Layout.minimumWidth: styleLoader.item ? styleLoader.item.Layout.minimumWidth : Kirigami.Units.gridUnit
    Layout.minimumHeight: styleLoader.item ? styleLoader.item.Layout.minimumHeight : Kirigami.Units.gridUnit
    Layout.preferredWidth: styleLoader.item ? styleLoader.item.Layout.preferredWidth : Layout.minimumWidth
    Layout.preferredHeight: styleLoader.item ? styleLoader.item.Layout.preferredHeight : Layout.minimumHeight

    onClicked: root.expanded = !root.expanded

    hoverEnabled: true
    QQC2.ToolTip {
        id: tooltip
        text: {
            var prefix = root.accountTitle ? root.accountTitle + " — " : ""
            if (root.hasError && !root.hasData) return prefix + root.errorMessage
            var parts = ["5h: " + Math.round(root.fiveHourUtil) + "%"]
            if (root.hasSevenDay) parts.push("7d: " + Math.round(root.sevenDayUtil) + "%")
            for (var i = 0; i < root.weeklyModels.length; i++) {
                var m = root.weeklyModels[i]
                var name = m.label.replace(/^Weekly \(|\)$/g, "")
                parts.push(name + ": " + Math.round(m.util) + "%")
            }
            var suffix = root.dataStale
                ? " (ultimo stato " + Qt.formatDateTime(root.lastUpdated, "dd/MM hh:mm") + ")" : ""
            return prefix + parts.join(" | ") + suffix
        }
        visible: compactRep.containsMouse
    }

    Loader {
        id: styleLoader
        anchors.fill: parent
        source: plasmoid.configuration.compactStyle === "gauge"
            ? "GaugeRepresentation.qml"
            : "BarsRepresentation.qml"
    }

    Kirigami.Icon {
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        width: Kirigami.Units.iconSizes.small
        height: width
        source: "data-warning"
        visible: root.hasError && !root.hasData
        color: Kirigami.Theme.negativeTextColor
    }
}
