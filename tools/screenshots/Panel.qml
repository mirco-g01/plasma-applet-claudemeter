import QtQuick
import QtQuick.Layouts

import org.kde.kirigami as Kirigami

// A floating Plasma panel, close enough to the stock Breeze one for a backdrop.
Rectangle {
    id: panel

    default property alias content: row.data

    implicitHeight: 44
    radius: 8
    color: Kirigami.Theme.backgroundColor
    border.color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.12)
    border.width: 1

    RowLayout {
        id: row
        anchors.fill: parent
        anchors.leftMargin: 6
        anchors.rightMargin: 6
        spacing: 6
    }
}
