# Folio

Music player + EPUB/PDF reader in one app, so you can listen while you read. SwiftUI, iOS 15+.
It combines SimplePlayer and SimpleReader and adds new reading features. Its bundle ID is
`com.junki3lab.folio`, so it installs next to your existing apps instead of replacing them.

## Features

**Reading**
- Library with covers, **0–100% progress bar** on every book, "Continue reading" card, sort by recent / title / progress
- In the reader: progress slider with live % (drag it to jump anywhere in the book), chapter name and pages left
- **Reading direction**: *Swipe Left* (turn pages like a book) or *Scroll Down* (one continuous page). Change it under **Aa**
- **Zoom**: pinch with two fingers, or use the − / + magnifier buttons. On EPUBs, zoom changes the text size and the text reflows, like Apple Books. On PDFs it's a real zoom
- **Highlights**: select text, then tap a color (yellow, green, blue or pink). "Highlight" is also in the text menu. Tap a highlight to copy it, add a note or remove it
- **Highlights tab**: every passage you marked, grouped by book. You can search it, and tapping one jumps back to that spot
- **Notes**: the small ✎ button in the bottom-right corner of the page opens a note editor. If text is selected, it's quoted in the note. Notes keep their page and appear in the Highlights tab under *Notes*
- Table of contents (EPUB nav/NCX and PDF outlines) plus per-book highlights and notes
- Four themes (Paper, Sepia, Dusk, Night), font choice (Book, Serif or Sans) and line spacing
- Tap the middle of the page to show or hide the controls. Tap the left or right edge to turn pages
- Remembers your position in every book

**Music**
- Import MP3, M4A, AAC, FLAC, WAV or AIFF. Shows artwork, artist and duration from the file's tags
- Mini player on every tab, and a now-playing strip inside the reader (♪ button for the full song list)
- Shuffle, repeat (all / one), scrubber, system volume, lock screen and Control Center controls
- Keeps playing in the background, pauses when headphones are unplugged and resumes after calls

**Battery**
- No timers run while music is paused or the app is in the background. The lock screen keeps time on its own
- The playback clock updates the UI once per second, and only redraws the small time views
- The reader runs no polling: position is saved when scrolling stops, and writes to disk are batched
- Covers and song artwork are shrunk and cached once
- Opening the app to read never interrupts audio from other apps

## Getting the .ipa (no Mac needed)

1. Create a new GitHub repo and upload everything in this folder. Keep the hidden `.github` folder.
2. Open the repo's **Actions** tab. The "Build unsigned IPA" workflow runs on every push, or you can press **Run workflow**.
3. When it finishes (about 3–5 minutes), download the **Folio-ipa** artifact and unzip it to get `Folio.ipa`.
4. Sideload it with Sideloadly or AltStore, the same way as SimplePlayer.

## Adding books and music

- Tap **+** in the Library (books) or Music (songs) tab, or
- Use "Open in Folio" / Share → Folio from Files, Mail, Safari or AudioGrab, or
- Connect your phone to a computer, then Finder (or iTunes) → your iPhone → Files → Folio, and drag files in.

Works with books that have no DRM.

## Building on a Mac instead

```sh
brew install xcodegen
xcodegen generate
open Folio.xcodeproj
```
