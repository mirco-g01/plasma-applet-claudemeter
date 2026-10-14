import QtQuick
import QtQuick.Layouts

import "defaults.js" as Defaults

// One widget instance with its own `plasmoid` stub and `root`, so a scene can
// hold several with different settings and data. The representation files
// resolve both names through this context, as they would in plasmashell.
Item {
    id: instance

    property var config: ({})
    property string payload: ""
    // The popup (fullRepresentation) instead of the panel view.
    property bool full: false
    // Height the panel gives the applet.
    property int thickness: 36
    // Shown in the popup footer, so it can agree with the panel clock.
    property string updatedAt: "14:32:05"

    implicitWidth: !loader.item ? 0 : full ? loader.item.implicitWidth : loader.item.Layout.preferredWidth
    implicitHeight: !loader.item ? 0 : full ? loader.item.implicitHeight : thickness

    QtObject {
        id: plasmoid
        property var configuration: Object.assign({}, Defaults.defaults, instance.config)
        property int formFactor: 2 // PlasmaCore.Types.Horizontal
    }

    Root { id: root }

    Loader {
        id: loader
        anchors.fill: parent
        source: Defaults.uiDir + (instance.full ? "FullRepresentation.qml" : "CompactRepresentation.qml")
    }

    Component.onCompleted: {
        root.parseUsageData(instance.payload)
        var parts = instance.updatedAt.split(":")
        var stamp = new Date()
        stamp.setHours(+parts[0], +parts[1], +parts[2])
        root.lastUpdated = stamp
    }
}
