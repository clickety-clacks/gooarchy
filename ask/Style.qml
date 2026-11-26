pragma Singleton

import QtQml

QtObject {
  readonly property int cornerRadius: 12
  readonly property int gapsOut: 12
  readonly property var font: ({ family: "sans-serif", body: 14, caption: 12, title: 20 })
  readonly property var spacing: ({ panelPadding: 18 })

  function space(pixels) { return pixels }
}
