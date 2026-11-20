# NotchViewer

A tiny VNC viewer for MacBooks with a notch. It draws the remote Mac's screen over the **entire**
built-in display, including the row beside the camera, so the remote menu bar sits next to the
notch, as if you were sitting at the other Mac. Apple's Screen Sharing can't do this: macOS keeps
its window below the camera row.

**Status: early prototype (v0.1).** Mouse, keyboard and scrolling work in principle; untested
against many setups. No audio (plain VNC has none).

## Use
```
./scripts/build_app.sh && open NotchViewer.app
```
Enter the remote Mac's address (Screen Sharing must be on there), its username and password.
Tick "Remember this login" once; after that, "Connect with Touch ID" unlocks the saved password from your Keychain.
On the remote Mac, enable Screen Sharing > "VNC viewers may control screen with password" and leave the username blank.
Disconnect with **Control-Option-Command-Q**.

## Limits / ideas
- ZRLE, CopyRect and Raw encodings.
- Apple ARD (type 30) and classic VNC (type 2) auth.
- Not done: clipboard sync, audio, remote cursor shape, multiple displays.

MIT licence.
