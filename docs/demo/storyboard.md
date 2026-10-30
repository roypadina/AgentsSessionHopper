# AgentsSessionHopper demo — storyboard (12.6 s, loops)

Real parts (compiled from `~/Code/Padina/AgentsSessionHopper` @ v1.2.0): `PopoverView.swift` (panel, profile rows, session rows, "Needs you" card, "Move…" menu),
`AppModel.swift` (one token changed in a build-dir copy: `snapshot` made settable so the scene can hand the real view a fake snapshot), and the engine
`SessionHopperCore` (HopperSnapshot / HopperConfig / ProfileLimits / LiveSession). The status glyph is the app's own `Assets/icons/menubar@2x.png`; the
badge / warning icons (monochrome SF Symbols drawn in `scene.swift`, not the kit's palette StatusItem) and the "show % next to the icon" rule are `MenuBarLabel` (`AgentsSessionHopperApp.swift:49-72`), copied with source comments in
`scene.swift`. Panel footer (About / Support on Ko-fi / Quit) = `AgentsSessionHopperApp.swift:14-17`. Thresholds are the defaults (suggest 85 %, park 97 %,
`Config.swift`). Fake data: profiles "Work" and "Personal", two sessions in `~/Code/app` and `~/Code/site`, usage Work 71 -> 87 %, Personal 24 -> 27 %.
Clock "Thu Oct 30 9:41 AM" (then 9:52, 9:54): every snapshot time is "today" at a fixed hour, so "resets 12:30" never depends on the render date.

| # | Scene | Start | Dur | What happens | Caption |
|---|-------|-------|-----|--------------|---------|
| 1 | menu bar | 0.0 | 2.0 | Menu bar only: the app's glyph and "71%" (the fullest live profile). No cursor. | Your fullest profile's usage sits in the menu bar |
| 2 | panel | 2.0 | 3.2 | Cursor glides to the status item, click: the panel opens at once under it: Work 71 % / Personal 24 % (5h and 7d, resets), the two live sessions. Late in the scene Work crosses 85 %: the status item turns into the badge icon with "87%" and the "Needs you" card appears. | See each profile's usage and its live sessions |
| 3 | asks | 5.2 | 2.4 | The card reads the suggestion for the session in `~/Code/app`; cursor glides to the real "Move to Personal at turn end" button. | Near its limit, it asks to continue elsewhere |
| 4 | confirm | 7.6 | 2.4 | Click: the card is answered at once (the row now says the move waits for turn end, state from the real model). At the turn end (9:54) the session runs on Personal and the hand-off appears under "Recent hand-offs". Cursor fades. | Confirm, and it moves when the turn ends |
| 5 | moved | 10.0 | 2.6 | Panel stays: the same session now sits under Personal, idle (a turn-end move adds no prompt; only the next prompt makes it "working"). Cursor glides to the desktop, click: the panel closes (click outside, like a `MenuBarExtra(.window)`). Last 0.2 s dissolves into scene 1 (clean loop). | Same conversation, continued on the other profile |

Transitions: 0.2 s crossfade between scenes; captions fade old 0–0.12 s / new 0.12–0.35 s (never two pills at once). State changes land inside a scene,
never on a scene boundary (two different panels crossfaded would ghost). Cursor: system arrow, eased glides on a slight arc, click = dip + ripple; visible
only while it points at something.
Render: `./render.sh` (from `docs/demo/`, writes `docs/demo.gif`) (compiles SessionHopperCore as a module, AppModel + PopoverView, kit, scene; 30 fps frames; encode).
