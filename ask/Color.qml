pragma Singleton

import QtQuick

QtObject {
  readonly property color accent: "#b6e1d5"
  readonly property QtObject menu: QtObject {
    readonly property color background: "#202624"
    readonly property color text: "#f0f4f1"
    readonly property color border: "#697b74"
    readonly property color scrim: "#65090d0b"
  }
}
