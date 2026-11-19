# Themes

**English** | [Русский](themes.ru.md)

The theme is chosen in Settings → General (and in the first-run wizard).
Besides the four built-in themes, the release ships themes in the `themes`
folder next to the launcher: **Ocean**, **Ruby**, **Gold**, **Steel**,
**Midnight** (black background) and the light **Daylight**.

## Editor

**New theme** opens the editor based on the current theme and always saves a
new one (the current theme stays as it is); **Edit** and
**Delete** are there for your own themes; **Themes folder** opens the folder
of your themes; ⟳ rereads the folders. The editor shows a live preview on the
right.

- **Colors**: dark or light, the main color (all shades are made from it) and,
  optionally, exact accent, background, panel and text colors. The color
  picker has swatches, hue / saturation / brightness and HEX.
- **Background picture**: one for all games and one per game; dimming, blur
  and the mode — Fill, Tile (repeated like a web page pattern) or Center, with
  the picture size.
- **Font**: a system font (a searchable list, each shown in its own font) or a
  `.ttf`/`.otf` file; text size, thickness, letter spacing and text shadow
  (color, blur, offset).
- **Corners**: your own rounding of buttons, tabs, cards, windows and fields.
- **Window**: the whole window's opacity (Linux needs a compositing window
  manager) and the Windows 11 backdrop — Mica or Acrylic (experimental) with a
  tint: how much the theme background covers the blurred backdrop (Windows
  sets the blur strength).
- **Music visualizer**: the colors of the bars' top and bottom.

Your themes are saved to the `themes` folder of the launcher data. The editor
copies the chosen pictures and font there too (`<theme>-<file>`), so a theme
can be shared with them; deleting a theme removes them.

## Format

A theme is a JSON file. Only `name` and `seed` are required; everything else
is made from `seed`.

```json
{
  "name": "Ocean",
  "dark": true,
  "seed": "#1E5BFF",
  "accent": "#5B8CFF",
  "background": "#0A0F1E",
  "panels": "#111A2E",
  "text": "#E6ECFF",
  "background_image": "ocean.jpg",
  "background_images": { "srb2kart": "kart.jpg" },
  "background_dim": 0.55,
  "background_blur": 4,
  "background_fit": "tile",
  "background_scale": 1.5,
  "font": "Ubuntu",
  "text_scale": 1.1,
  "font_weight": 1,
  "letter_spacing": 0.5,
  "text_shadow": { "color": "#AA000000", "blur": 3, "x": 1, "y": 1 },
  "radius": 14,
  "window_opacity": 0.95,
  "backdrop": "acrylic",
  "backdrop_opacity": 0.3,
  "visualizer": ["#00E5FF", "#2962FF"]
}
```

| Field | Meaning |
|---|---|
| `name` | Theme name. |
| `dark` | Dark (`true`, the default) or light. |
| `seed` | Main color: all shades are made from it. |
| `accent` | Exact accent color: buttons, selection, the current tab. |
| `background` | Window background. |
| `panels` | Cards, dialogs, tab buttons. |
| `text` | Text color. |
| `background_image` | Background picture for all games. |
| `background_images` | Pictures per game: game code → picture. |
| `background_dim` | How much the background covers the picture: 0–1 (default 0.55). |
| `background_blur` | Picture blur, 0–40. |
| `background_fit` | `cover` (fill, the default), `tile`, `center`. |
| `background_scale` | Picture size for `tile` and `center` (1 = as is). |
| `font` | A system font name or a `.ttf`/`.otf` file. |
| `text_scale` | Text size, 0.7–1.6. |
| `font_weight` | Thickness: −3 to +3 steps. |
| `letter_spacing` | Letter spacing. |
| `text_shadow` | Text shadow: `color`, `blur`, `x`, `y`. |
| `radius` | Corner rounding, 0–40. |
| `window_opacity` | Window opacity, 0.4–1. |
| `backdrop` | Windows 11 backdrop: `none`, `mica`, `acrylic`. |
| `backdrop_opacity` | How much the theme background covers the backdrop, 0–1 (default 0.35). |
| `visualizer` | Visualizer bar colors: `[top, bottom]` or one color. |

- Colors are `#RRGGBB` or `#AARRGGBB`.
- File paths are relative to the theme's JSON.
- A theme put into a folder by hand shows up after ⟳ or a restart.
- A theme in the data folder wins over a shipped theme with the same file
  name.
