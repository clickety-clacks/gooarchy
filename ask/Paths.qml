pragma Singleton

import QtQml
import Quickshell

QtObject {
  readonly property string settings: (Quickshell.env("XDG_CONFIG_HOME")
    || Quickshell.env("HOME") + "/.config") + "/gooarchy/ask.json"

  function bridge(name) {
    return Quickshell.shellDir + "/bridge/" + name
  }
}
