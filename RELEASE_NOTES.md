## What's Changed
- **⌃⇥ / ⌃⇧⇥ move between columns.** The standard next/previous-tab keys now step one column right or left, wrapping around at either end. Requested in [#1](https://github.com/bujna94/infinityTerminal/issues/1).
- **Keyboard navigation now moves keyboard focus.** Stepping to a column focuses a pane there, so what you type lands where you just navigated. Previously ⌥⌘←/→ scrolled the view but left focus behind, and keystrokes went to a pane that had scrolled off screen.
- **⌥⌘↑ / ⌥⌘↓ move between the panes stacked in a column.** Maximized panes restore to an even split first, so focus never lands on the collapsed strip.
- Sideways movement keeps its row: the bottom pane stays the bottom pane as you cross columns. Trackpad scrolling and minimap drags still leave focus alone, so peeking at another column never pulls the cursor out of a running command.
