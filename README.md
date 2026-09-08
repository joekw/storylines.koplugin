# Storylines sync for KOReader

Sends your reading to [Storylines](https://storylines.software): where you are in each
book, every reading session with the time you actually spent, and the status, rating and
review you set on the device.

Runs alongside KOReader's built-in Progress sync — it has its own settings and doesn't
touch the `custom_server` slot, so if you already sync to your own kosync server, that
keeps working.

## What it sends

| | |
|---|---|
| **Position** | Your place in the book, as a percentage |
| **Sessions** | Each sitting from KOReader's own statistics, with its real duration |
| **Metadata** | Title, authors, series, language and the EPUB's identifiers, so the right book is matched without you linking anything |
| **Status** | Reading, on hold or finished, from KOReader's book status |
| **Rating and review** | The 1–5 stars and the note you set in KOReader |

Nothing is sent until you pair. The only things read are `statistics.sqlite3`
and the per-book sidecar files KOReader already keeps — both through KOReader's
own APIs, which means opening a sidecar can prune an invalid one, the same as
browsing your library does.

Nothing is ever written back to your books or your reading position: sync is
one-way, from the device to Storylines.

## Install

**From Storefront** — open **Tools → Storefront**, search for "Storylines", install. Also
works from the older App Store plugin.

**By hand** — download `storylines.koplugin.zip` from
[Releases](https://github.com/joekw/storylines.koplugin/releases), unzip it, and copy the
`storylines.koplugin` folder into KOReader's plugin directory:

| Device | Path |
|---|---|
| Kindle | `/mnt/us/koreader/plugins/` |
| Kobo | `.adds/koreader/plugins/` |
| Android | `koreader/plugins/` |
| Desktop | `~/.config/koreader/plugins/` |

Restart KOReader afterwards — plugins are only picked up at startup.

## Pair

1. In Storylines: **Settings → Import → Kindle sync**, then **Show pairing code**.
2. On your e-reader: **Tools → Storylines sync → Pair with Storylines**, and type the code.

The code lasts ten minutes. Pairing is per device, so a phone and a Kobo can both sync to
the same library.

On a Kindle, also set KOReader's Wi-Fi action to "turn on Wi-Fi", or it can't reach the
network to sync without you connecting by hand each time.

## When it syncs

On closing a book, shortly afterwards to catch the sitting that just ended, when the
network comes back, and every
50 page turns. **Tools → Storylines sync → Sync now** forces it, and **Sync
automatically** turns the rest off if you'd rather it only ran when you ask.

The first sync sends your whole reading history. Storylines asks before importing it,
because it will change your streak and your statistics.

## Requirements

Storylines Plus, and KOReader with the statistics plugin enabled (it is by default —
without it there are no sessions to send, only positions).

## Privacy

Your reading goes to Storylines' own sync server and nowhere else. Unpairing from the app
deletes it; **Disconnect** in the app's settings deletes the whole sync account.

The plugin holds a token it got when you paired, in
`koreader/settings/storylines.lua`. There is no password, and the token is only good for
writing to your own account.
