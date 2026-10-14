import QtQuick
import QtQuick.Layouts
import QtQuick.Effects

import org.kde.kirigami as Kirigami

import "demo.js" as Demo

// The panel views side by side: both styles, the gauge's labels and inner
// ring, the account label, custom colours and the threshold colours.
Shot {
    id: shot

    readonly property real now: Date.now()
    readonly property string maxData: Demo.payload(Demo.max, now)
    readonly property string proData: Demo.payload(Demo.pro, now)
    readonly property string criticalData: Demo.payload(Demo.critical, now)
    readonly property string midData: Demo.payload(Demo.mid, now)

    component Tile: ColumnLayout {
        id: tile
        default property alias content: strip.data
        property string caption
        spacing: 8
        Layout.alignment: Qt.AlignTop

        Rectangle {
            Layout.alignment: Qt.AlignHCenter
            implicitWidth: Math.max(strip.implicitWidth + 24, 96)
            implicitHeight: 44
            radius: 8
            color: Kirigami.Theme.backgroundColor
            border.color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.12)
            border.width: 1

            RowLayout {
                id: strip
                anchors.centerIn: parent
                spacing: 10
            }
        }
        Text {
            Layout.alignment: Qt.AlignHCenter
            Layout.preferredWidth: 170
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            text: tile.caption
            color: "white"
            font.family: Kirigami.Theme.defaultFont.family
            font.pixelSize: 12
        }
    }

    Item {
        id: scene
        width: grid.implicitWidth + 64
        height: grid.implicitHeight + 64
        clip: true

        Image {
            id: wallpaper
            anchors.fill: parent
            source: "file:///usr/share/wallpapers/Next/contents/" + (shot.dark ? "images_dark" : "images") + "/5120x2880.png"
            sourceSize.width: 1920
            fillMode: Image.PreserveAspectCrop
            visible: false
        }
        MultiEffect {
            anchors.fill: parent
            source: wallpaper
            blurEnabled: true
            blurMax: 64
            blur: 1.0
            brightness: shot.dark ? -0.25 : -0.1
        }

        GridLayout {
            id: grid
            anchors.centerIn: parent
            columns: 3
            columnSpacing: 24
            rowSpacing: 28

            Tile {
                caption: "Bars: 5-hour, weekly and each model's weekly"
                Instance { payload: shot.maxData; Layout.preferredWidth: implicitWidth; Layout.preferredHeight: implicitHeight }
            }
            Tile {
                caption: "Gauge with time to reset, or percent"
                Instance { payload: shot.maxData; config: ({ compactStyle: "gauge", gaugeInnerMetric: "none" }); Layout.preferredWidth: implicitWidth; Layout.preferredHeight: implicitHeight }
                Instance { payload: shot.maxData; config: ({ compactStyle: "gauge", gaugeInnerMetric: "none", gaugeLabel: "percent" }); Layout.preferredWidth: implicitWidth; Layout.preferredHeight: implicitHeight }
            }
            Tile {
                caption: "Inner ring: a second limit at a glance"
                Instance { payload: shot.maxData; config: ({ compactStyle: "gauge", gaugeLabel: "percent" }); Layout.preferredWidth: implicitWidth; Layout.preferredHeight: implicitHeight }
                Instance { payload: shot.maxData; config: ({ compactStyle: "gauge", compactMetric: "seven_day", gaugeInnerMetric: "five_hour", gaugeLabel: "percent" }); Layout.preferredWidth: implicitWidth; Layout.preferredHeight: implicitHeight }
            }
            Tile {
                caption: "Account label, for several accounts"
                Instance { payload: shot.maxData; config: ({ accountLabel: "MAX" }); Layout.preferredWidth: implicitWidth; Layout.preferredHeight: implicitHeight }
                Instance { payload: shot.proData; config: ({ accountLabel: "PRO" }); Layout.preferredWidth: implicitWidth; Layout.preferredHeight: implicitHeight }
            }
            Tile {
                caption: "Your own colours"
                Instance { payload: shot.midData; config: ({ normalColor: "#3DAEE9" }); Layout.preferredWidth: implicitWidth; Layout.preferredHeight: implicitHeight }
                Instance { payload: shot.midData; config: ({ compactStyle: "gauge", normalColor: "#27AE60", gaugeInnerMetric: "none" }); Layout.preferredWidth: implicitWidth; Layout.preferredHeight: implicitHeight }
                Instance { payload: shot.midData; config: ({ compactStyle: "gauge", normalColor: "#9B59B6", gaugeLabel: "percent" }); Layout.preferredWidth: implicitWidth; Layout.preferredHeight: implicitHeight }
            }
            Tile {
                caption: "Warning and critical colours near the limit"
                Instance { payload: shot.criticalData; Layout.preferredWidth: implicitWidth; Layout.preferredHeight: implicitHeight }
                Instance { payload: shot.criticalData; config: ({ compactStyle: "gauge", gaugeLabel: "percent" }); Layout.preferredWidth: implicitWidth; Layout.preferredHeight: implicitHeight }
            }
        }
    }
}
