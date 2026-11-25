//@ pragma AppId org.gooarchy.Ask
//@ pragma ShellId gooarchy-ask
//@ pragma CacheDir $BASE/gooarchy/ask

import QtQml
import Quickshell
import Quickshell.Io

ShellRoot {
  Ask { id: ask }

  IpcHandler {
    target: "gooarchy-ask"
    function toggle(): void { ask.toggle() }
  }

  Component.onCompleted: ask.open()
}
