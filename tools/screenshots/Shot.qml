import QtQuick
import QtQuick.Window

// Shows its content in a window, saves it to the path render.py passes after
// `--`, and quits. render.py sets the pixel ratio to 2.
Window {
    id: shot

    default property alias content: canvas.data
    property alias canvas: canvas
    readonly property var args: Qt.application.arguments
    readonly property string target: args[args.length - 2]
    readonly property string theme: args[args.length - 1]
    readonly property bool dark: theme === "dark"

    width: canvas.width
    height: canvas.height
    visible: true
    color: "transparent"
    flags: Qt.FramelessWindowHint

    Item {
        id: canvas
        width: childrenRect.width
        height: childrenRect.height
    }

    Timer {
        // Long enough for icons, fonts and the first frame of every chart.
        interval: 900
        running: true
        // Without a target size the grab is taken at the window's pixel ratio.
        onTriggered: canvas.grabToImage(function (result) {
            if (!result.saveToFile(shot.target)) console.error("could not write " + shot.target)
            Qt.quit()
        })
    }
}
