## What's Changed
- **Experimental: vertical scrolling mode**. A new toggle flips the grid 90° — columns stack top-to-bottom with two side-by-side panes per row, and the canvas scrolls vertically instead of horizontally. Switch modes from the new **View** menu, or click the **↔ / ↕** segmented control in the toolbar. Choice persists across launches.
- **Shift+scroll** in vertical mode moves the grid; plain vertical scroll continues to feed the terminal's own scrollback so existing terminal navigation is unchanged.
- **Active-pane outline is twice as thick** (1pt → 2pt) so the focused terminal is easier to spot at a glance, especially in wide grids.
- Layout under the hood now uses custom SwiftUI `Layout` types instead of `if/else` stack swapping, so the orientation toggle preserves running PTYs and their content across the flip.
