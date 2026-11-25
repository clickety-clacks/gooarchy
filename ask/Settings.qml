import QtQuick
import QtQuick.Controls
import Quickshell

FloatingWindow {
  id: root
  visible: false
  title: "Gooarchy Ask Settings"
  color: Color.menu.background
  implicitWidth: 600
  implicitHeight: 860
  minimumSize: Qt.size(480, 520)

  // Agent
  property string agent: ""
  property string model: ""
  property string reasoningEffort: ""
  readonly property var modelChoices: [{ label: "System harness settings", value: "" }].concat(agent === "claude" ? [
    { label: "Opus 4.8", value: "claude-opus-4-8" },
    { label: "Opus 5", value: "claude-opus-5" },
    { label: "Fable 5", value: "claude-fable-5" },
    { label: "Fable 5.1", value: "claude-fable-5-1" }
  ] : [
    { label: "Luna", value: "gpt-5.6-luna" },
    { label: "Terra", value: "gpt-5.6-terra" },
    { label: "Sol (GPT-5.6)", value: "gpt-5.6-sol" },
    { label: "Astra", value: "gpt-6-astra" }
  ])
  signal agentApplied(string agent, string model, string reasoningEffort)

  // Scroll motion
  property real impulse: 335
  property real deceleration: 608
  readonly property real duration: impulse / deceleration
  readonly property real distance: impulse * impulse / (2 * deceleration)
  signal motionChanged(real impulse, real deceleration)
  signal resetRequested()
  function open() {
    syncModelIndex()
    visible = true
    curve.requestPaint()
    Qt.callLater(function() {
      if (!root.visible) return
      var window = root.contentItem.Window.window
      if (window) window.requestActivate()
      modelSelect.forceActiveFocus()
    })
  }

  function finish() { visible = false }
  function cancel() { visible = false }

  function syncModelIndex() {
    if (agent === "") { modelSelect.currentIndex = -1; return }
    for (var i = 0; i < modelChoices.length; i++) {
      if (modelChoices[i].value === model) {
        modelSelect.currentIndex = i
        return
      }
    }
    modelSelect.currentIndex = 0
  }

  function chooseAgent(nextAgent) {
    if (agent === nextAgent) return
    agentApplied(nextAgent, "", "")
    Qt.callLater(root.syncModelIndex)
  }

  function setFromEndpoint(seconds, pixels) {
    var t = Math.max(0.08, Math.min(2.5, seconds))
    var d = Math.max(4, Math.min(600, pixels))
    // s(t) = v₀t - ½at², with v(t)=0 at the endpoint.
    // Therefore v₀=2s/t and a=2s/t².
    motionChanged(2 * d / t, 2 * d / (t * t))
  }

  Shortcut { sequence: "Escape"; onActivated: root.cancel() }
  Shortcut { sequence: "Ctrl+,"; onActivated: root.finish() }

  component Heading: Text {
    color: Color.menu.text
    font.family: Style.font.family
    font.pixelSize: Style.font.title
    font.bold: true
  }
  component Caption: Text {
    width: parent.width
    color: Qt.rgba(Color.menu.text.r, Color.menu.text.g, Color.menu.text.b, 0.58)
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    wrapMode: Text.Wrap
  }
  component Label: Text {
    color: Color.menu.text
    font.family: Style.font.family
    font.pixelSize: Style.font.body
  }
  component Choice: Rectangle {
    property string label
    property bool selected
    signal chosen()
    width: choiceLabel.implicitWidth + Style.space(22)
    height: Style.space(34)
    radius: Style.cornerRadius
    color: selected ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.18) : "transparent"
    border.color: selected ? Color.accent : Color.menu.border
    Text {
      id: choiceLabel
      anchors.centerIn: parent
      text: parent.label
      color: Color.menu.text
      font.family: Style.font.family
      font.pixelSize: Style.font.body
    }
    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: parent.chosen() }
  }
  Flickable {
    anchors.fill: parent
    contentHeight: content.implicitHeight + Style.space(56)
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    Column {
      id: content
      x: Style.space(28)
      y: Style.space(28)
      width: parent.width - Style.space(56)
      spacing: Style.space(14)

      // --- Agent ---------------------------------------------------------
      Heading { text: "Agent" }
      Caption { text: "Choose an installed, signed-in harness. App search works without one." }
      Row {
        spacing: Style.space(8)
        Repeater {
          model: ["", "codex", "claude"]
          delegate: Choice {
            required property string modelData
            label: modelData || "No harness"
            selected: root.agent === modelData
            onChosen: root.chooseAgent(modelData)
          }
        }
      }
      Label { text: "Model" }
      ComboBox {
        id: modelSelect
        enabled: root.agent !== ""
        displayText: root.agent === "" ? "System harness settings" : currentText
        width: parent.width
        height: Style.space(42)
        model: root.modelChoices
        textRole: "label"
        valueRole: "value"
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        onActivated: root.agentApplied(root.agent, currentValue, root.reasoningEffort)
      }
      Label { text: "Thinking" }
      Row {
        spacing: Style.space(7)
        enabled: root.agent !== ""
        opacity: enabled ? 1 : 0.5
        Repeater {
          model: ["", "low", "medium", "high", "xhigh", "max"]
          delegate: Choice {
            required property string modelData
            label: modelData || "System default"
            selected: root.reasoningEffort === modelData
            onChosen: root.agentApplied(root.agent, root.model, modelData)
          }
        }
      }

      Item { width: 1; height: Style.space(10) }

      // --- Scroll motion -------------------------------------------------
      Heading { text: "Scroll motion" }
      Caption {
        text: "Drag the endpoint. Right means a longer coast; up means farther travel. The curve is the viewport’s position after one navigation-key impulse."
      }
      Rectangle {
        id: graph
        width: parent.width
        height: Style.space(300)
        color: Qt.rgba(Color.menu.text.r, Color.menu.text.g, Color.menu.text.b, 0.035)
        border.color: Qt.rgba(Color.menu.text.r, Color.menu.text.g, Color.menu.text.b, 0.14)
        border.width: 1
        radius: Style.cornerRadius

        Canvas {
          id: curve
          anchors.fill: parent
          property real leftPad: Style.space(48)
          property real rightPad: Style.space(24)
          property real topPad: Style.space(24)
          property real bottomPad: Style.space(42)
          readonly property real plotWidth: width - leftPad - rightPad
          readonly property real plotHeight: height - topPad - bottomPad
          readonly property real endX: leftPad + Math.min(1, root.duration / 2.5) * plotWidth
          readonly property real endY: height - bottomPad - Math.min(1, root.distance / 600) * plotHeight

          onWidthChanged: requestPaint()
          onHeightChanged: requestPaint()
          Connections {
            target: root
            function onImpulseChanged() { curve.requestPaint() }
            function onDecelerationChanged() { curve.requestPaint() }
          }

          onPaint: {
            var ctx = getContext("2d")
            ctx.reset()
            var bottom = height - bottomPad
            var right = width - rightPad

            ctx.lineWidth = 1
            ctx.strokeStyle = Qt.rgba(Color.menu.text.r, Color.menu.text.g, Color.menu.text.b, 0.18)
            ctx.beginPath()
            ctx.moveTo(leftPad, topPad)
            ctx.lineTo(leftPad, bottom)
            ctx.lineTo(right, bottom)
            ctx.stroke()

            ctx.lineWidth = Math.max(2, Style.space(2))
            ctx.strokeStyle = Color.accent
            ctx.beginPath()
            for (var index = 0; index <= 48; index++) {
              var u = index / 48
              var seconds = root.duration * u
              var pixels = root.impulse * seconds
                - 0.5 * root.deceleration * seconds * seconds
              var x = leftPad + (seconds / 2.5) * plotWidth
              var y = bottom - (pixels / 600) * plotHeight
              if (index === 0) ctx.moveTo(x, y)
              else ctx.lineTo(x, y)
            }
            ctx.stroke()

            ctx.fillStyle = Color.accent
            ctx.beginPath()
            ctx.arc(endX, endY, Style.space(7), 0, Math.PI * 2)
            ctx.fill()
          }

          MouseArea {
            anchors.fill: parent
            preventStealing: true
            cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
            onPressed: function(mouse) { update(mouse.x, mouse.y) }
            onPositionChanged: function(mouse) { if (pressed) update(mouse.x, mouse.y) }
            function update(x, y) {
              var seconds = (x - curve.leftPad) / curve.plotWidth * 2.5
              var pixels = (curve.height - curve.bottomPad - y) / curve.plotHeight * 600
              root.setFromEndpoint(seconds, pixels)
            }
          }
        }

        Text {
          anchors.left: parent.left
          anchors.bottom: parent.bottom
          anchors.leftMargin: Style.space(10)
          anchors.bottomMargin: Style.space(10)
          text: "distance"
          color: Qt.rgba(Color.menu.text.r, Color.menu.text.g, Color.menu.text.b, 0.42)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
        Text {
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          anchors.rightMargin: Style.space(12)
          anchors.bottomMargin: Style.space(10)
          text: "time →"
          color: Qt.rgba(Color.menu.text.r, Color.menu.text.g, Color.menu.text.b, 0.42)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }
      Row {
        width: parent.width
        spacing: Style.space(22)
        Label { text: "impulse  " + Math.round(root.impulse) + " px/s" }
        Label { text: "friction  " + Math.round(root.deceleration) + " px/s²" }
        Label { text: root.distance.toFixed(0) + " px · " + root.duration.toFixed(2) + " s"; color: Color.accent }
      }
      Choice { label: "Reset"; selected: false; onChosen: root.resetRequested() }
    }
  }

}
