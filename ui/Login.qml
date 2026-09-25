import QtQuick
import QtQuick.Controls.Basic

// Sign-in card. Password goes to the helper's stdin and is never stored.
// The session lands in the same cookie directory Omarchy iCloud Photos uses.
Item {
  id: root

  required property var theme
  property string username: ""
  property string step: "credentials" // credentials | code
  property bool busy: false
  property string error: ""

  signal submitCredentials(string username, string password)
  signal submitCode(string code)
  signal previewSample()

  function reset() {
    step = "credentials"
    busy = false
    error = ""
    passwordField.text = ""
    codeField.text = ""
  }

  function focusFirst() {
    if (step === "code") codeField.forceActiveFocus()
    else if (usernameField.text.length === 0) usernameField.forceActiveFocus()
    else passwordField.forceActiveFocus()
  }

  onVisibleChanged: if (visible) focusFirst()
  onStepChanged: focusFirst()

  component Field: TextField {
    id: field
    width: 320
    height: 38
    color: theme.brightForeground
    placeholderTextColor: theme.darkForeground
    font.family: theme.fontFamily
    font.pixelSize: theme.fontSize + 1
    leftPadding: 12
    rightPadding: 12
    selectByMouse: true
    background: Rectangle {
      radius: 6
      color: theme.background
      border.width: field.activeFocus ? 2 : 1
      border.color: field.activeFocus ? theme.accent : theme.lighterBackground
    }
  }

  component ActionButton: Rectangle {
    id: btn
    property string label: ""
    property bool primary: true
    property bool enabled: true
    signal clicked()
    activeFocusOnTab: true
    width: 320
    height: 38
    radius: 6
    color: !enabled ? theme.muted
         : (activeFocus || btnArea.containsMouse)
           ? (primary ? Qt.lighter(theme.accent, 1.12) : theme.selection)
           : (primary ? theme.accent : theme.lighterBackground)
    border.width: activeFocus ? 2 : 0
    border.color: theme.brightForeground
    Text {
      anchors.centerIn: parent
      text: btn.label
      color: btn.primary ? theme.darkerBackground : theme.brightForeground
      font.family: theme.fontFamily
      font.pixelSize: theme.fontSize
      font.bold: true
    }
    MouseArea {
      id: btnArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: btn.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: if (btn.enabled) btn.clicked()
    }
    Keys.onReturnPressed: if (btn.enabled) btn.clicked()
    Keys.onEnterPressed: if (btn.enabled) btn.clicked()
  }

  Rectangle {
    anchors.centerIn: parent
    width: card.implicitWidth + 64
    height: card.implicitHeight + 56
    radius: 12
    color: theme.darkBackground
    border.color: theme.lighterBackground
    border.width: 1

    Column {
      id: card
      anchors.centerIn: parent
      spacing: 12
      width: 320

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: "OHealth"
        color: theme.accent
        font.family: theme.fontFamily
        font.pixelSize: 22
        font.bold: true
      }
      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: root.step === "code" ? "Enter the verification code" : "Sign in with Apple"
        color: theme.brightForeground
        font.family: theme.fontFamily
        font.pixelSize: 17
        font.bold: true
      }
      Text {
        width: 320
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap
        text: root.step === "code"
          ? "Apple sent a six-digit code to your trusted devices. It confirms the iCloud session. It does not download HealthKit."
          : "Apple ID and password open an iCloud session, the same cookie jar Omarchy iCloud Photos uses. The password is not stored. Health data still has to come from an export on this machine."
        color: theme.darkForeground
        font.family: theme.fontFamily
        font.pixelSize: theme.fontSize - 1
      }

      Item { width: 1; height: 4 }

      Column {
        spacing: 10
        visible: root.step === "credentials"
        Field {
          id: usernameField
          text: root.username
          placeholderText: "Apple ID"
          inputMethodHints: Qt.ImhEmailCharactersOnly | Qt.ImhNoAutoUppercase
          onAccepted: passwordField.forceActiveFocus()
        }
        Item {
          width: 320
          height: 38
          Field {
            id: passwordField
            anchors.fill: parent
            placeholderText: "Password"
            echoMode: showPassword.checked ? TextInput.Normal : TextInput.Password
            rightPadding: 72
            onAccepted: signInButton.clicked()
          }
          Text {
            id: showPassword
            property bool checked: false
            anchors.right: parent.right
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            text: checked ? "Hide" : "Show"
            color: eyeArea.containsMouse || checked ? theme.foreground : theme.darkForeground
            font.family: theme.fontFamily
            font.pixelSize: theme.fontSize - 1
            MouseArea {
              id: eyeArea
              anchors.fill: parent
              anchors.margins: -6
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                showPassword.checked = !showPassword.checked
                passwordField.forceActiveFocus()
              }
            }
          }
        }
        ActionButton {
          id: signInButton
          label: root.busy ? "Signing in…" : "Sign in"
          enabled: !root.busy && usernameField.text.trim().length > 0 && passwordField.text.length > 0
          onClicked: {
            root.error = ""
            root.busy = true
            root.submitCredentials(usernameField.text.trim(), passwordField.text)
          }
        }
        ActionButton {
          label: "Preview sample data"
          primary: false
          enabled: !root.busy
          onClicked: root.previewSample()
        }
        Text {
          width: 320
          wrapMode: Text.Wrap
          horizontalAlignment: Text.AlignHCenter
          text: "Sample numbers are invented. Ctrl+P from this card. Esc quits."
          color: theme.darkForeground
          font.family: theme.fontFamily
          font.pixelSize: theme.fontSize - 2
        }
      }

      Column {
        spacing: 10
        visible: root.step === "code"
        Field {
          id: codeField
          placeholderText: "123456"
          horizontalAlignment: TextInput.AlignHCenter
          font.pixelSize: 22
          font.letterSpacing: 6
          maximumLength: 6
          inputMethodHints: Qt.ImhDigitsOnly
          validator: RegularExpressionValidator { regularExpression: /[0-9]{0,6}/ }
          onTextChanged: if (text.length === 6 && !root.busy) verifyButton.clicked()
          onAccepted: verifyButton.clicked()
        }
        ActionButton {
          id: verifyButton
          label: root.busy ? "Verifying…" : "Verify"
          enabled: !root.busy && codeField.text.length === 6
          onClicked: {
            root.error = ""
            root.busy = true
            root.submitCode(codeField.text)
          }
        }
      }

      Text {
        visible: root.error.length > 0
        width: 320
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap
        text: root.error
        color: theme.red
        font.family: theme.fontFamily
        font.pixelSize: theme.fontSize - 1
      }
    }
  }
}
