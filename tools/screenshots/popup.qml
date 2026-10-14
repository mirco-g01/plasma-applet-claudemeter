import QtQuick

import "demo.js" as Demo

// The popup alone, on a transparent background with room for its shadow.
Shot {
    id: shot

    Item {
        width: popup.implicitWidth + 80
        height: popup.implicitHeight + 80

        PopupFrame {
            id: popup
            anchors.centerIn: parent
            width: implicitWidth
            height: implicitHeight
            config: ({ accountLabel: "MAX" })
            payload: Demo.payload(Demo.max, Date.now())
        }
    }
}
