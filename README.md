# utilBox

utilBox is a menu-bar app for macOS 13 and later. It keeps a clipboard shelf and a scratchpad on the same Mac. There is no account and no network. The app has no Dock icon.

One mailbox icon sits at the right of the menu bar, beside Control Center. Click it to open the clipboard with the scratchpad directly underneath. Drag a file, some text, or an image onto that icon and the clipboard opens on its own, so you can drop it in. A plain hover, with nothing on the cursor, leaves the icon closed. Clipboard history and notes stay in `~/Library/Application Support/utilBox/`.

## Download and use

Build it on a Mac. The Xcode app is optional. The Xcode Command Line Tools are enough, and the project has no third-party dependencies.

```bash
git clone https://github.com/denelbjohn18/utilBox.git
cd utilBox
xcode-select --install
./build.sh
./install.sh
open /Applications/utilBox.app
```

`xcode-select --install` is only needed once. `./build.sh` runs the tests, then writes `dist/utilBox.app` and `dist/utilBox.dmg`. `./install.sh` copies that disk image into `/Applications`, clears the quarantine flag, and ad-hoc signs the copy on this Mac. It does not launch the app. After it finishes, open `/Applications/utilBox.app`. The mailbox icon shows up at the top right.

Send friends the disk image from `./build.sh` (`dist/utilBox.dmg`). That file is unsigned so another Mac can open it. The ad-hoc signature from `./install.sh` belongs on the Mac that created it. The same signature is often reported as damaged on a different Mac.

### Disk image from a release

Pushing a tag named `v1.0.0`, or any name that starts with `v`, builds the disk image and attaches `utilBox.dmg` to that GitHub release. After the release exists, this downloads it:

```bash
curl -fL -o utilBox.dmg https://github.com/denelbjohn18/utilBox/releases/latest/download/utilBox.dmg
open utilBox.dmg
```

Drag utilBox to Applications. The first open uses the steps in the next section. The disk image also contains `Install utilBox.command`. Double-clicking it copies utilBox into Applications and clears the download quarantine flag. macOS may ask once about that installer, because the installer is unsigned too.

## The first time a downloaded copy opens

utilBox ships unsigned. Notarizing an app takes a paid Apple Developer membership, which this project leaves unused. The first time someone opens a downloaded copy, macOS says the developer cannot be verified. That question shows up once.

1. Click Done on the warning.
2. Right-click utilBox and choose Open, then Open. On newer macOS the same control is in System Settings → Privacy & Security → Open Anyway.
3. Later launches open from the menu-bar icon directly.

`./install.sh` is for the Mac that just built the app. It ad-hoc signs `/Applications/utilBox.app` on that machine. A friend who receives `utilBox.dmg` uses the Right-click → Open step above.

## Scratchpad

Click the mailbox to open the scratchpad under the clipboard. Click the mailbox again to hide both. The close button, or Command-W, hides the scratchpad and leaves the clipboard as it is. The page is warm cream paper: a soft gradient, a fine grain, and a light vignette, with warm brown type.

The left column lists your notes. From there you can collapse the list, add a note, or search. The black Copy button copies the whole note onto the clipboard. The next Command-V pastes it, and the shelf keeps that copy too.

Shrink the card to a black pill labeled Scratchpad. Drag the pill anywhere on the screen. Click the pill to open the card again. The round button on the pill copies the current note.

While the card or the pill is open, it stays above other apps, browsers, fullscreen windows, and Spaces. Switching apps leaves it where you put it. Hide it with the close button or Command-W. Clicking the mailbox while the clipboard is open with it hides both. Typing in a note leaves it open. Notes remain on this Mac until you delete them.

A new note takes its title from the first line. An empty note is titled Untitled. The pad holds 200 notes, and each note holds 200,000 characters. utilBox remembers whether the scratchpad was open, whether it was a pill, and where you left it, and restores that the next time it launches.

## Clipboard

Click the mailbox to open the shelf and the scratchpad together. The shelf hangs under the icon, and the scratchpad sits under the shelf. Click the mailbox again to hide both. Click outside the shelf, or press Esc, to close the shelf and leave the scratchpad where it is.

Drag a file, text, or an image onto the mailbox and the shelf opens by itself. Drop it on the icon or on the shelf to keep it. Move that drag away, without dropping, and the shelf closes. Hovering the mailbox with an empty cursor does not open it.

utilBox keeps the last 100 copies, plus up to 50 you pin. Click an item and utilBox writes it back to the system clipboard, then closes the shelf. Press Command-V in the app you were already using. That paste lands there. When the scratchpad is open, the same click leaves the scratchpad in place.

You can drop text, an image, or files onto the open shelf. The drop keeps the item and leaves the current clipboard selection alone until you click that item.

Copies are captured while utilBox is running. Items marked concealed, transient, or auto-generated are skipped. Password managers usually set those flags.

## Day to day

- Click the mailbox to show the clipboard and the scratchpad, one under the other. Click it again to hide both. Drag the card by its top bar, or drag the pill.
- Drag a file onto the mailbox to open the clipboard and drop it in. With nothing on the cursor, click the mailbox.
- Click a clipboard row. The row shows a check, the shelf closes, and Command-V pastes that item.
- Search filters the shelf. Up and down move through the results, Return selects one, and Esc clears the search and then closes the shelf. Esc in the scratchpad clears its search and leaves the pad open.
- Pin holds an item above the rest. The shelf holds 50 pins. Pinning one more beeps.
- The × removes one item. Clear Unpinned, in the ··· menu, removes every item that is not pinned.
- Drag a row out to drop it on another app. Drag something onto the shelf to keep a copy.
- Quit and Open at Login are in that same menu, and also on a right-click of the mailbox. Open at Login stays off until you turn it on. If macOS refuses the setting, put utilBox in Applications and try again.

Text, images, and files are all kept. A copied image stays an image. A file copied from Finder stays a file, including when Finder also puts a preview picture on the clipboard. The shelf keeps the newest 100 unpinned items and drops the oldest when you copy something new.

## Privacy

History and notes live at `~/Library/Application Support/utilBox/`. The files are readable only by that user. Quitting the app leaves them in place. To remove them, quit utilBox and delete that folder.

utilBox reads the clipboard only while it is running. It does not ask for Accessibility access. Choosing a shelf item, or copying a note, writes the system clipboard. You press Command-V yourself.

## Uninstall

Turn Open at Login off if you enabled it. Quit utilBox, then move `/Applications/utilBox.app` to the Trash. Delete `~/Library/Application Support/utilBox` when you want the saved copies and notes gone too.

## Tests

`make test` compiles the clipboard and scratchpad rules and runs them. On a Mac it uses the Swift compiler from the Command Line Tools. `./build.sh` is what produces the app and the disk image, and it runs on macOS.

## License

MIT. See [LICENSE](LICENSE).
