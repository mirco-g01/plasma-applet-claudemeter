import QtQuick
import QtQuick.Effects

import org.kde.kirigami as Kirigami

// A Plasma applet popup holding the widget's real fullRepresentation.
Item {
    id: popup

    property alias config: inst.config
    property alias payload: inst.payload
    property alias updatedAt: inst.updatedAt
    readonly property int pad: 8

    implicitWidth: inst.implicitWidth + 2 * pad
    implicitHeight: inst.implicitHeight + 2 * pad

    RectangularShadow {
        anchors.fill: frame
        radius: frame.radius
        blur: 28
        offset.y: 6
        color: Qt.rgba(0, 0, 0, 0.45)
    }

    Rectangle {
        id: frame
        anchors.fill: parent
        radius: 8
        color: Kirigami.Theme.backgroundColor
        border.color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.12)
        border.width: 1
    }

    Instance {
        id: inst
        full: true
        x: popup.pad
        y: popup.pad
        width: implicitWidth
        height: implicitHeight
    }
}
