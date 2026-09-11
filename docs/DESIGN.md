# quizzle design system

**Design language: Bauhaus**, with Bento Box modularity for dense/dashboard screens.

## Why Bauhaus (not negotiable, build to it)

1. The Bauhaus was a *school*. For an education product the reference is conceptual, not decorative.
2. The app's answer tiles already use triangle / diamond / circle / square — that is literally
   Bauhaus geometric vocabulary. This is an evolution of what exists, not a costume.
3. Bauhaus is form-follows-function: flat planes, hard edges, primary accents on a restrained
   ground, type as structure. That produces high contrast by default, which fixes the
   accessibility failures in the previous palette instead of fighting them.
4. It gives a calm authoring surface and a loud, legible play surface from one vocabulary.

**What that means concretely**

- Flat colour planes. No gradients, no glassmorphism, no drop shadows used decoratively.
  Elevation is communicated by a **2px navy border** and offset, not blur.
- Hard 90° corners by default. `borderRadius: 0` is the default; a pill (`999px`) is allowed
  **only** for chips/badges and the join-code field. Never `rounded-lg` everywhere.
- Asymmetric, grid-driven composition. Content sits on a visible 12-column rhythm.
- Geometric primitives as functional signals: the four answer shapes, circles for avatars,
  squares for status, a single diagonal or quarter-circle per screen as accent — used once,
  never scattered.
- Type is structure: heavy condensed display against light body, big size jumps, no timid steps.

## Colour tokens

The four supplied colours are the **structural system**. Navy is the "black" of the composition,
Ice Mist the "white". Accents are a small, deliberate extension — the app needs four
distinguishable answer colours and correct/wrong semantics, which four cool blues cannot provide.

```
STRUCTURAL (supplied — do not alter)
--navy        #26374d   primary ink, dark surfaces, all borders
--slate       #536d82   secondary text, inactive states
--dusty-blue  #9db3bf   dividers, disabled, muted fills
--ice-mist    #dde6ed   light page ground

DERIVED NEUTRALS
--paper       #FFFFFF   cards/surfaces on the ice ground
--navy-deep   #1A2735   dark-theme ground (darker than navy so navy reads as a surface)
--navy-surf   #2F4459   dark-theme raised surface

ANSWER TILES (white bold text — all verified >= 4.5:1)
--ans-red     #B3262A   6.51:1   triangle
--ans-blue    #1B4F9C   7.94:1   diamond
--ans-amber   #8A6100   5.54:1   circle
--ans-green   #1B6B4A   6.46:1   square

SEMANTIC (verified on ice ground)
--correct     #137445   4.60:1
--wrong       #A81F23   5.76:1
--warn        #7A5500   5.31:1
```

**Verified contrast — respect these limits**

| pairing | ratio | allowed for |
|---|---|---|
| navy on ice | 9.57:1 | anything |
| navy on white | 12.10:1 | anything |
| white on navy | 12.10:1 | anything |
| ice on navy | 9.57:1 | anything |
| slate on white | 5.42:1 | anything |
| **slate on ice** | **4.29:1** | **large text only (>=18.66px bold / 24px regular)** |
| dusty on navy | 5.55:1 | anything |

Never put `--dusty-blue` text on `--ice-mist`. Never put small `--slate` text on `--ice-mist`.

Both themes are required. Dark theme: `--navy-deep` ground, `--navy-surf` surfaces,
`--ice-mist` text, `--dusty-blue` secondary text. Answer tiles keep the same fills in both
themes (they are already dark enough for white text and must stay recognisable).

## Type

Two Google Fonts, three roles. Load via `google_fonts` and set
`GoogleFonts.config.allowRuntimeFetching = false` with the fonts bundled in `pubspec.yaml`
assets so nothing depends on network at runtime.

- **Display — `Archivo Black`** (or `Archivo` w700 if Black is unavailable). Geometric grotesque,
  very heavy. Used for screen titles, the join code, scores, the podium. Tight tracking
  (`letterSpacing: -0.02em`), `height: 1.0` on large sizes.
- **Body — `Archivo`** w400/w500/w600. Same family, lighter weights: keeps the page coherent
  while the weight jump does the hierarchy work.
- **Data/label — `Archivo` w600 uppercase, `letterSpacing: 0.12em`, 11–12px** for eyebrows,
  metadata and stat labels. Bauhaus loves the stencilled label.

Type scale (stay on it): 56 / 40 / 28 / 22 / 17 / 15 / 13 / 11.

Never hard-code `fontSize` in a widget. Everything comes from the `TextTheme`, so system text
scaling works. Tiles and cards must size to content, never a fixed `childAspectRatio`.

## Motion

Bauhaus motion is **mechanical and purposeful** — things slide, wipe, and snap along axes.
No bounce, no elastic, no floaty fades.

```
--dur-instant  90ms    state feedback (tap, toggle)
--dur-quick    180ms   enter/exit of small elements
--dur-base     260ms   page and panel transitions
--dur-slow     420ms   reveal moments (answer, podium)
--ease-out     Curves.easeOutCubic      entering
--ease-in-out  Curves.easeInOutCubic    moving
--ease-snap    Cubic(0.2, 0, 0, 1)      decisive, Bauhaus default
```

Required animations (these are the deliverable, not optional polish):

1. **Route transitions** — horizontal plane slide + wipe, `--dur-base`, `--ease-snap`.
   Not the default Material fade.
2. **Staggered entry** — lists and bento grids stagger children 40ms apart on first build,
   sliding 16px along one axis. Resting state is visible; never park at `opacity: 0`.
3. **Countdown** — a square ring that depletes, not a spinner. Colour steps navy → amber →
   red at 50% / 20%. At <=5s the whole ring pulses once per second (scale 1.0→1.04).
4. **Answer tile tap** — press scales to 0.97 at `--dur-instant`; on lock-in the chosen tile
   slides a 4px navy offset shadow (Bauhaus block-print feel) and the others desaturate.
5. **Reveal** — correct tile wipes to `--correct` from the left over `--dur-slow`; wrong choice
   cross-fades to `--wrong`; a horizontal bar chart of the answer distribution grows from 0.
6. **Leaderboard** — rank changes animate position with `AnimatedList`/implicit slide, and the
   score number counts up (`TweenAnimationBuilder`), tabular figures so digits don't jitter.
7. **Podium** — the three blocks rise from 0 height, staggered 2nd → 1st → 3rd.
8. **Join code** — letters stagger in on session create, 40ms apart.

Respect `MediaQuery.disableAnimationsOf(context)`: when true, jump to end state, run nothing.

## Layout

- 12-column grid, 24px gutter desktop / 16px mobile. Never less than 16px side padding.
- Breakpoints stay as they are: <600 compact, <1024 medium, >=1024 expanded.
- **Bento Box** for the educator dashboard and analytics: unequal modular tiles on a fixed grid,
  every tile a flat plane with a 2px navy border, one tile allowed to span 2 columns. Tiles size
  to content; no tile stretches over dead space.
- Reading measure max 68ch for any prose.
- Every table/chart/code block that can overflow gets its own horizontal scroll container.
  The page body must never scroll sideways.

## Accessibility — non-negotiable, this was audited and failed before

- Every `IconButton` gets a `tooltip` **and** a semantic label.
- Each answer tile: `Semantics(button: true, label: 'Option A, <text>')`. The option letter must
  be conveyed as text, never by colour or shape alone.
- Score, timer and reveal outcome are `liveRegion: true` so screen readers announce them.
- Countdown announces at 10s and 5s.
- Focus moves to the question heading on advance.
- Minimum 48x48 touch targets.
- Visible focus ring: 2px navy outline, 2px offset, on every interactive element.
