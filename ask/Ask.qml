import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

Item {
  id: root

  property var activeOverlay: null
  property var conversations: []
  property int conversationSequence: 0
  // The manager owns the font scale so every conversation — overlay or pinned
  // window — reads one value and a single writer persists it.
  readonly property real minFontScale: 0.7
  readonly property real maxFontScale: 2
  readonly property string settingsPath: Paths.settings
  property real fontScale: 1
  // How long typing has to pause before the menu search recomputes. Matching
  // is cheap; the resize it triggers is not, so this is really a tolerance
  // for how much the card is allowed to move while you type. Settable in
  // ask.json, which is watched, so an edit applies without a restart.
  readonly property int minSearchDebounceMs: 0
  readonly property int maxSearchDebounceMs: 2000
  property int searchDebounceMs: 270
  property real keyboardLineImpulse: 335
  property real keyboardDeceleration: 608
  property var fileOpenCommand: []
  property var fileEditCommand: []
  property int repoSearchDepth: 6
  property string selectedAgent: ""
  property string selectedModel: ""
  property string selectedReasoningEffort: ""
  readonly property real keyboardPageImpulse: keyboardLineImpulse * (740 / 360)
  property bool settingsLoaded: false
  // Keep the complete decoded object so adding a setting never erases fields
  // owned by a newer Ask build or the image-paste extension.
  property var persistedSettings: ({})
  // Retained so writing the font scale cannot drop the mode the bridge owns.
  property string persistedPermissionMode: "permission"
  property bool copyToastVisible: false
  function showCopyToast() {
    copyToastFade.stop()
    copyToastCard.opacity = 1
    copyToastVisible = true
    copyToastHold.restart()
  }

  function setFontScale(value) {
    var next = Math.max(minFontScale, Math.min(maxFontScale, Math.round(value * 100) / 100))
    if (next === fontScale) return
    fontScale = next
    if (settingsLoaded) settingsSaveTimer.restart()
  }

  function adjustFontScale(step) { setFontScale(fontScale + step) }

  function setKeyboardMotion(impulse, deceleration) {
    var nextImpulse = Math.round(Math.max(80, Math.min(2000, impulse)))
    var nextDeceleration = Math.round(Math.max(100, Math.min(5000, deceleration)))
    if (nextImpulse === keyboardLineImpulse && nextDeceleration === keyboardDeceleration) return
    keyboardLineImpulse = nextImpulse
    keyboardDeceleration = nextDeceleration
    if (settingsLoaded) settingsSaveTimer.restart()
  }

  function loadSettings(raw) {
    var data = {}
    try { data = JSON.parse(raw || "{}") } catch (error) { data = {} }
    if (!data || typeof data !== "object" || Array.isArray(data)) data = {}
    persistedSettings = data
    persistedPermissionMode = data.permissionMode === "yolo" ? "yolo" : "permission"
    var scale = Number(data.fontScale)
    fontScale = (isFinite(scale) && scale > 0)
      ? Math.max(minFontScale, Math.min(maxFontScale, scale))
      : 1
    var debounce = Number(data.searchDebounceMs)
    searchDebounceMs = isFinite(debounce)
      ? Math.round(Math.max(minSearchDebounceMs, Math.min(maxSearchDebounceMs, debounce)))
      : 270
    var impulse = Number(data.keyboardLineImpulse)
    keyboardLineImpulse = isFinite(impulse)
      ? Math.round(Math.max(80, Math.min(2000, impulse)))
      : 335
    var deceleration = Number(data.keyboardDeceleration)
    keyboardDeceleration = isFinite(deceleration)
      ? Math.round(Math.max(100, Math.min(5000, deceleration)))
      : 608
    fileOpenCommand = normalizeCommand(data.fileOpenCommand)
    fileEditCommand = normalizeCommand(data.fileEditCommand)
    var repoDepth = Number(data.repoSearchDepth)
    repoSearchDepth = isFinite(repoDepth)
      ? (repoDepth <= 0 ? 0 : Math.max(1, Math.min(128, Math.round(repoDepth))))
      : 6
    selectedAgent = String(data.agent || "")
    selectedModel = selectedAgent ? String(data.model || "") : ""
    selectedReasoningEffort = selectedAgent ? String(data.reasoningEffort || "") : ""
    settingsLoaded = true
  }

  function normalizeCommand(value) {
    if (typeof value === "string")
      return value.trim() === "" ? [] : [value.trim()]
    if (!Array.isArray(value)) return []
    var command = []
    for (var i = 0; i < value.length; i++) {
      var argument = String(value[i] || "")
      if (argument !== "") command.push(argument)
    }
    return command
  }

  function flushSettings() {
    if (!settingsLoaded) return
    var output = {}
    var existing = persistedSettings && typeof persistedSettings === "object"
      && !Array.isArray(persistedSettings)
      ? persistedSettings : ({})
    var keys = Object.keys(existing)
    for (var i = 0; i < keys.length; i++) output[keys[i]] = existing[keys[i]]
    output.permissionMode = persistedPermissionMode
    output.fontScale = fontScale
    output.searchDebounceMs = searchDebounceMs
    output.keyboardLineImpulse = keyboardLineImpulse
    output.keyboardDeceleration = keyboardDeceleration
    output.fileOpenCommand = fileOpenCommand
    output.fileEditCommand = fileEditCommand
    output.repoSearchDepth = repoSearchDepth
    output.agent = selectedAgent
    output.model = selectedModel
    output.reasoningEffort = selectedReasoningEffort
    persistedSettings = output
    settingsFile.setText(JSON.stringify(output, null, 2) + "\n")
  }

  FileView {
    id: settingsFile
    path: root.settingsPath
    watchChanges: true
    atomicWrites: true
    blockLoading: true
    printErrors: false
    onLoaded: root.loadSettings(text())
    // First run: the file does not exist yet. Without this the scale would
    // never be marked loaded and would never be written.
    onLoadFailed: root.loadSettings("")
    onFileChanged: reload()
  }

  Timer {
    id: settingsSaveTimer
    interval: 200
    repeat: false
    onTriggered: root.flushSettings()
  }

  Settings {
    id: settings
    agent: root.selectedAgent
    model: root.selectedModel
    reasoningEffort: root.selectedReasoningEffort
    impulse: root.keyboardLineImpulse
    deceleration: root.keyboardDeceleration
    onAgentApplied: function(nextAgent, nextModel, nextReasoningEffort) {
      root.selectedAgent = nextAgent
      root.selectedModel = nextModel
      root.selectedReasoningEffort = nextReasoningEffort
      settingsSaveTimer.restart()
    }
    onMotionChanged: function(nextImpulse, nextDeceleration) {
      root.setKeyboardMotion(nextImpulse, nextDeceleration)
    }
    onResetRequested: root.setKeyboardMotion(335, 608)
  }

  PanelWindow {
    id: copyToast
    visible: root.copyToastVisible
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "gooarchy-ask-copied"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    mask: Region { item: copyToastCard }

    Rectangle {
      id: copyToastCard
      width: copyToastText.implicitWidth + Style.space(42)
      height: Style.space(58)
      anchors.horizontalCenter: parent.horizontalCenter
      y: Math.round(parent.height * 0.22)
      color: AskPalette.menu.background
      radius: Style.cornerRadius
      border.color: AskPalette.accent
      border.width: 2

      Text {
        id: copyToastText
        anchors.centerIn: parent
        text: "✓  Copied!"
        color: AskPalette.accent
        font.family: Style.font.family
        font.pixelSize: Math.round(Style.font.body * (4 / 3))
        font.bold: true
      }
    }

    Timer {
      id: copyToastHold
      interval: 1500
      onTriggered: copyToastFade.restart()
    }

    NumberAnimation {
      id: copyToastFade
      target: copyToastCard
      property: "opacity"
      from: 1
      to: 0
      duration: 500
      easing.type: Easing.OutQuad
      onFinished: root.copyToastVisible = false
    }
  }

  Component {
    id: conversationComponent
    Conversation {}
  }

  function removeConversation(conversation) {
    if (activeOverlay === conversation) activeOverlay = null
    var remaining = []
    for (var i = 0; i < conversations.length; i++) {
      if (conversations[i] !== conversation) remaining.push(conversations[i])
    }
    conversations = remaining
    if (remaining.length === 0 && settings.visible) settings.finish()
    Qt.callLater(function() { conversation.destroy() })
  }

  function createConversation(payloadJson) {
    var conversation = conversationComponent.createObject(root)
    if (!conversation) return null
    conversationSequence++
    conversation.windowTitle = "Gooarchy Ask #" + conversationSequence
    conversations = conversations.concat([conversation])
    activeOverlay = conversation
    conversation.fontScale = Qt.binding(function() { return root.fontScale })
    conversation.searchDebounceMs = Qt.binding(function() { return root.searchDebounceMs })
    conversation.keyboardLineImpulse = Qt.binding(function() { return root.keyboardLineImpulse })
    conversation.keyboardPageImpulse = Qt.binding(function() { return root.keyboardPageImpulse })
    conversation.keyboardDeceleration = Qt.binding(function() { return root.keyboardDeceleration })
    conversation.fileOpenCommand = Qt.binding(function() { return root.fileOpenCommand })
    conversation.fileEditCommand = Qt.binding(function() { return root.fileEditCommand })
    conversation.agentName = root.selectedAgent
    conversation.modelName = root.selectedModel
    conversation.reasoningEffort = root.selectedReasoningEffort
    conversation.permissionMode = root.persistedPermissionMode
    conversation.settingsOpen = Qt.binding(function() { return settings.visible })
    conversation.fontScaleStepRequested.connect(function(step) { root.adjustFontScale(step) })
    conversation.fontScaleResetRequested.connect(function() { root.setFontScale(1) })
    conversation.settingsRequested.connect(function() {
      if (settings.visible) settings.finish()
      else settings.open()
    })
    conversation.sessionRestartRequested.connect(function() {
      conversation.agentName = root.selectedAgent
      conversation.modelName = root.selectedModel
      conversation.reasoningEffort = root.selectedReasoningEffort
    })
    conversation.copyConfirmed.connect(function() { root.showCopyToast() })
    conversation.permissionModeConfirmed.connect(function(mode) {
      root.persistedPermissionMode = mode === "yolo" ? "yolo" : "permission"
      settingsSaveTimer.restart()
    })
    conversation.closed.connect(function() { root.removeConversation(conversation) })
    conversation.pinnedChanged.connect(function() {
      if (conversation.pinned && root.activeOverlay === conversation)
        root.activeOverlay = null
    })
    conversation.open(payloadJson || "{}")
    return conversation
  }

  function open(payloadJson) {
    if (activeOverlay && activeOverlay.opened && !activeOverlay.pinned) return
    if (!settingsLoaded) settingsFile.text()
    createConversation(payloadJson)
  }

  function close() {
    if (activeOverlay && activeOverlay.opened && !activeOverlay.pinned)
      activeOverlay.close()
  }

  function pinActive() {
    if (activeOverlay && activeOverlay.opened && !activeOverlay.pinned)
      activeOverlay.pinConversation()
  }

  function closeAll() {
    if (settings.visible) settings.finish()
    var snapshot = conversations.slice()
    for (var i = 0; i < snapshot.length; i++) snapshot[i].close()
  }

  function toggle(payloadJson) {
    if (activeOverlay && activeOverlay.opened) close()
    else open(payloadJson)
  }
}
