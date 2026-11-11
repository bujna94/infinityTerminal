## What's Changed
- **⌥⌘C copies the selection as one line.** Claude Code wraps long lines itself, inserting real line breaks and indentation, so copying a long command it printed pasted as several broken lines. The new shortcut, also available as **Copy as One Line** in the right-click menu, joins the selection back into a single line: each line is trimmed, blank lines and trailing `\` continuations are dropped, and the pieces are joined with single spaces. Plain ⌘C is unchanged.
- **Selections no longer drift in full-screen apps.** Claude Code, vim and less scroll by redrawing the screen, so the text slid under a selection that stayed put and ⌘C copied something other than what you picked. The selection is now cleared when the text under it changes.
- **Claude Code's own highlight clears when you select normally.** After an ⌥-drag, Claude Code draws and copies its own selection; a later plain drag now clears it instead of leaving two highlights on screen.

Replaces v1.0.31, whose Copy as One Line menu item was always greyed out.
