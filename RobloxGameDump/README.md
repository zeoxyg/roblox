# Roblox Game Dump

`GameDump.lua` is a Roblox Studio plugin that collects the open place's
hierarchy (names, classes, attributes, tags) and the full source of every
`Script`, `LocalScript` and `ModuleScript` into one text view.

## Install (once)

1. In Roblox Studio, create a `Script` in **ServerScriptService**.
2. Paste the contents of `GameDump.lua` into it.
3. Right-click the Script in Explorer and choose **Save as Local Plugin**.
4. Delete the Script from the place. The plugin stays installed.

## Use

1. Open your place in Studio (edit mode, not playtest).
2. Click **Dump Game** on the **Game Dump** toolbar.
3. Click inside the "Game Dump" window, press **Ctrl+A** then **Ctrl+C**.
4. Paste it into a `.txt` file, or paste it into the chat.

Studio plugins cannot write files to disk, so the dump is shown in a window
for copying. For large games the text can be very long; in that case, save
it to a `.txt` file and attach that instead of pasting.

## Notes

- `CoreGui`, `CorePackages` and `Players` are skipped.
- If a script's source cannot be read, its entry says so instead of failing
  the whole dump.
- For a real file tree (one folder per instance, one `.luau` file per
  script), use [Rojo](https://rojo.space/) and its `rojo syncback` command
  instead.
