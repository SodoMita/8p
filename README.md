# EIGHT PAGES

A dark-forest survival-horror game in the spirit of **Slender: The Eight Pages**,
built with **Godot 4.7** (GDScript, GL Compatibility renderer). Collect eight
pages pinned to landmarks in a pitch-black wood while a very tall figure watches
from the tree line. Every texture, sound and mesh in this project is generated
from code — there are no third-party assets.

The forest is **photoreal-leaning, not stylised**: the trees are bare dead
trunks and snags (no leaves, no needle cards) built from tapered, bark-UV-mapped
meshes, and the ground is a procedural PBR material — albedo, normal and
roughness maps generated from layered value noise, scattered needle litter,
twigs and pebbles, moss settling into the hollows. Nothing is painted by hand.

**It is genuinely dark.** Ambient light is a cold 0.42 with the moon at 0.24, so
the flashlight is the only real light source: a 30° cone that carves a pool of
dirt and bark out of black. The far distance dissolves into fog rather than
fading into grey.

### The boundary, and what lies past it

The playable wood is a 122 m square, and the square is **fenced**. The boundary is
built the way a real chain-link fence is built: 3 m wire-mesh bays between
galvanised posts, a top rail, bottom tension wire, and a two-leaf vehicle gate at
the east side that hangs open. The mesh is a genuine alpha-scissor diamond weave,
not a painted-on band, and every post, bay and gate leaf carries its own collider
(a ring of 325 shapes, verified arithmetically in the test suite rather than by
watching a character walk into it).

Past the gate there is **no edge to fall off**. An endless, procedurally streamed
forest continues in 32 m chunks around the player, and a dirt road leaves through
the gate and wanders off to the horizon, so an escaped player always has somewhere
to walk. A 4 km collision slab sits under all of it.

### Pages you can touch

Each page is a small **verlet cloth sheet** — 7×9 vertices pinned along its top
edge, integrated at a fixed 60 Hz, three constraint passes, shear links so it
cannot fold into a fan of triangles, and smoothed per-vertex normals computed from
the live geometry. It sags under its own weight and stirs in the draft. The pages
carry **no light of their own**; a whisper of emission keeps them readable at the
edge of the beam, and everything else you see on them is the flashlight.

### Concrete that holds up close

Concrete and stone use a **world-space triplanar** projection at 1.2 m per texture
repeat: 2048² maps give ~1700 px/m on every face regardless of whether that face
belongs to a 1 m pillar or a 20 m wall. Before that, box-mesh UVs gave 100–3500
px/m on the same wall with up to 46:1 stretch. The maps themselves are isotropic
layered noise with Poisson-scattered aggregate, pits, bubbles, chips and hairline
cracks, mipmapped and anisotropic-filtered.

![title](screenshots/00_title.jpg)
![gameplay](screenshots/gameplay.gif)

---

## Running it

### 1. From source (Godot 4.7+)

```bash
./eight_pages/run.sh                     # runs the game with the bundled Godot
# or with your own install:
godot --path eight_pages res://scenes/Title.tscn
godot -e --path eight_pages              # opens the editor
```

`run.sh` uses `$GODOT` if set, otherwise the Godot 4.7 binary in `../tools/`,
otherwise whatever `godot` is on your PATH.

### 2. Pre-built binaries (`build/`)

| Platform | File | Notes |
|---|---|---|
| **Web / mobile browsers** | `build/web/index.html` | pre-built; serve over HTTP (see below) |
| **Android** | `build/android/eight_pages.apk` | signed release APK v1.3.0 (arm64-v8a) |
| **Linux** | build it yourself (preset included) | `--export-release "Linux" build/linux/EightPages.x86_64` |

Build them yourself:

```bash
godot --headless --path eight_pages --export-release "Web"     build/web/index.html
godot --headless --path eight_pages --export-release "Android" build/android/eight_pages.apk
godot --headless --path eight_pages --export-release "Linux"   build/linux/EightPages.x86_64
```

The shipped APK is arm64-v8a only to keep it small — flip
`architectures/armeabi-v7a` / `x86_64` back on in `export_presets.cfg` for wider
device support. The web export targets WebGL 2 via the GL Compatibility
renderer and needs no cross-origin isolation headers.

Serve the web build locally (the browser needs HTTP, not `file://`):

```bash
cd eight_pages/build/web && python3 -m http.server 8080
# then open http://localhost:8080
```

For phones on the same network use your machine's LAN IP, and on iOS/Android
add the page to the home screen for a full-screen, no-browser-chrome experience.

---

## Controls

| Action | Keyboard / mouse | Touch |
|---|---|---|
| Move | `W A S D` / arrows | floating stick — drag anywhere on the left half |
| Look | mouse | drag anywhere on the right half |
| Sprint | `Shift` (drains breath) | hold **RUN** |
| Flashlight | `F` | **LIGHT** button |
| Take page | `E` (or simply walk into it) | **TAKE** button (auto-pickup also works) |
| Pause | `Esc` | **II** in the top-right corner |
| Dismiss a note | any of the above keys | it fades on its own |

Touch mode is detected automatically on mobile, Android/iOS web builds and any
device reporting a touchscreen. You can force it from **Settings → Force touch
controls**, or toggle it live in the pause menu.

---

## The rules of the forest

* Eight pages are pinned to eight landmarks: **concrete walls, a tunnel, a silo,
  a truck, a shed, a ring of stones, a ruined bathroom and a watchtower**.
* **Pumpkins and dead bushes.** Patches of ribbed, dirt-streaked pumpkins grow
  in the clearings and around every landmark (some knocked over), and dense
  leafless bushes — branched twig clumps, not painted billboards — fill the
  undergrowth, thickest toward the tree line.
* **Every run is laid out from a fresh seed.** The landmark order, their
  positions and rotations, their individual variations (a shed with or without
  a lean-to, a truck on its wheels or flipped, one wall or a broken run of
  three…), the page spots, the forest density, the undergrowth and the ground
  debris are all randomised. Landmarks keep a circular 24–30 m spacing and never
  spawn within 14 m of the tree-line clearing you start in, and every page spot
  is validated as reachable before it is used.
* He appears at the edge of the trees. **While you look at him he cannot move**
  — every time you look away he is closer.
* **Stare too long and he charges.** Sprint will not save you for long.
* Static is his voice. It rises with his presence and with the number of pages
  in your pocket; heartbeat speed is distance.
* The flashlight dies when he is close (or when you point it at him).
* Eight pages collected = you escape. Anything less = *he found you*.

Difficulty ramps with every page: shorter apparition cooldowns, faster approach,
quicker chases.

---

## Project layout

```
eight_pages/
├── project.godot            # GL Compatibility, canvas_items stretch, input map
├── export_presets.cfg       # Web / Android / Linux presets
├── scenes/
│   ├── Title.tscn           # menu, settings, how-to-play
│   ├── World.tscn           # the run: map builder + player + slender + HUD
│   └── Player.tscn          # CharacterBody3D, camera, flashlight
├── scripts/
│   ├── game.gd              # autoload: state, input routing, quality/touch detection
│   ├── settings.gd          # autoload: persisted settings (user://settings.cfg)
│   ├── sfx.gd               # autoload: looping ambience + one-shot pool
│   ├── title.gd             # title screen UI
│   ├── world.gd             # run orchestration, pages, static feedback, endings
│   ├── map_builder.gd       # procedural forest, eight landmarks, chain-link boundary
│   ├── endless_terrain.gd   # streamed forest + road outside the fence
│   ├── page_cloth.gd        # verlet cloth sheet for each collectible page
│   ├── road_ribbon.gd       # crowned ribbon mesh builder for the road
│   ├── player.gd            # FPS controller (mouse + touch), stamina, head bob
│   ├── slender.gd           # the tall one: apparitions, gaze logic, chase, kill
│   ├── hud.gd               # all gameplay UI in code (no .tscn needed)
│   ├── touch_controls.gd    # virtual stick / swipe look / buttons
│   ├── autotest.gd          # scripted runs + screenshot tours
│   ├── selftest.gd          # 38 functional assertions
│   └── flowtest.gd          # Title → BEGIN → World → pause → pickup
├── shaders/
│   ├── static.gdshader      # film-grain / VHS static overlay
│   └── vignette.gdshader
├── assets/
│   ├── audio/*.wav          # synthesised wind, drone, static, heartbeat, steps…
│   ├── textures/*.png       # PBR ground/bark/stone/grass/litter, paper, noise
│   ├── models/*.res         # baked tree / snag / log / stump / shrub / pumpkin / bush meshes
│   └── fonts/               # DejaVu Sans + Serif (licence: Bitstream Vera / public)
├── run.sh                   # launcher (bundled Godot or your own)
├── VERSION.txt
├── tools/
│   ├── gen_assets.py        # regenerates base textures, sounds, title plate
│   ├── gen_textures_real.py # PBR ground/bark/stone/grass/litter maps
│   ├── gen_trees.gd         # bakes the bare-tree meshes into assets/models
│   ├── gen_title_bg.gd      # renders the menu backdrop from the tree meshes
│   ├── gen_concrete.py      # 2048² concrete albedo/normal/rough, isotropic
│   ├── setup_toolchain.sh   # JDK 21 + Android SDK + keystores + templates
│   ├── run_sway.sh          # headless sway compositor + Godot runner
│   ├── capture_screens.sh   # full screenshot capture inside sway
│   ├── web_capture.py       # Playwright capture of the web build (desktop + phone)
│   └── test_all.sh          # the whole verification suite
└── screenshots/             # sway-rendered captures used by this README
```

---

## Testing

Everything below runs headless — no physical display required.

```bash
tools/test_all.sh                  # 38 assertions + scripted runs in sway
tools/test_all.sh --with-web --with-android
```

What the suite covers (`tools/test_all.sh`, logs in `/tmp/eight_test_out`):

| Check | What it proves |
|---|---|
| `selftest` | **every tree triangle is wound to match its vertex normals** and every face survives a "step out along the normal and shoot back" test (nothing is inside-out), set pieces built, **the chain-link fence is a closed ring of 325 colliders with an open 5 m gate**, pages are live cloth with no light of their own and normals facing forward, endless terrain chunks + road exist and a second floor slab catches anything that leaves the fence, 8 distinct pages in bounds, layouts differ between seeds, landmarks spread ≥18 m, every page spot walkable, win bookkeeping saves a best time, walking/sprinting, stamina, mouse & touch look, wall + floor collision, pickup → HUD → note → Slender woken, gaze detection, chase → capture → death screen |
| `win path` | scripted collection of all 8 pages reaches the win screen |
| `death path` | Slender catches the player, jumpscare, death screen shown |
| `flow` | **Title → BEGIN → World → pause → resume → movement → first pickup**, inside sway, plus *picking up a page while paused is impossible* |
| `desktop shots` | 20 sway-rendered screenshots of every landmark, Slender, HUD, note overlay |
| `mobile shots` | same tour at phone resolution with touch UI; asserts the injected virtual-stick drag produced the expected move vector |
| `endings` | pause menu, jumpscare and death screen captures |
| `win screen` | win sequence capture |

The game itself also ships with the harness used by those tests:

```bash
# inside sway (real Wayland session):
tools/run_sway.sh res://scenes/World.tscn -- --autotest=selftest
tools/run_sway.sh res://scenes/World.tscn -- --autotest=shots --quality=1
tools/run_sway.sh res://scenes/World.tscn -- --autotest=shots --quality=0 --touch
tools/run_sway.sh res://scenes/Title.tscn -- --flow
```

### Code audit

`audit/` keeps the prompts and transcripts of the static-audit passes run with
[opencode](https://opencode.ai), including two deepseek agents run in parallel
during the 1.3.0 correction cycle (`audit/agents/CONCRETE_PBR.md` measured texel
density surface by surface; `audit/agents/CLOTH_TERRAIN.md` found eleven real
bugs in the cloth solver and the terrain streamer, all fixed). The `glm-5.3-flash` pass over the nine gameplay
scripts produced twelve findings; all twelve were applied and are covered by the
suite (boundary-fence orientation, Slender facing/pathing, paused pickups,
win-time bookkeeping, stamina, jumpscare framing, tween leaks, audio-loop tweens).

### How sway is used

`tools/run_sway.sh` starts `sway` on the **headless** backend with the **pixman**
software renderer (the sandbox has no `/dev/dri`), waits for the Wayland socket,
then launches Godot with `--display-driver wayland --rendering-driver opengl3`.
Screenshots come from Godot's own viewport texture; `grim` is used for whole-screen
captures such as the title. The same script is what the mobile-resolution runs use,
with `--touch` forcing the mobile UI.

### Quality tiers

`--quality=0|1|2` (auto-detected: software GL → 0, Intel/Mali/Adreno → 1,
everything else → 2) tunes fog, shadow casting, glow, tree count and particle-free
lighting so the game stays playable on phones and on `llvmpipe`.

---

## Regenerating assets

```bash
python3 tools/gen_assets.py       # base textures, audio, paper — run this FIRST
python3 tools/gen_textures_real.py   # PBR ground / bark / stone / grass / litter
godot --headless --path . --script tools/gen_trees.gd     # bare-tree meshes
godot --path . --script tools/gen_title_bg.gd             # menu backdrop (needs GL)
godot --headless --path . --import                        # refresh .import files
```

`gen_assets.py` overwrites the old flat textures, so always regenerate in that
order — `gen_textures_real.py` must come last or its PBR maps are replaced by the
painted ones.

* **Textures** — `gen_textures_real.py` builds tiling **PBR sets** (albedo,
  normal, roughness) for soil, bark and concrete from layered value noise plus
  Poisson-scattered needles, twigs and pebbles; `gen_assets.py` supplies the aged
  paper, the note sheet, the UI noise and the audio. The menu backdrop is a real
  render of the bare-tree meshes (`gen_title_bg.gd`), not a painting.
* **Meshes** — `gen_trees.gd` bakes six trunks, two snags, a fallen log, a stump
  and a dead shrub as `.res` meshes with world-space bark UVs and visible root
  flares; they are drawn with `MultiMesh` and per-instance tints.
* **Audio** — all WAVs are synthesised: wind and drone beds (cross-faded into
  seamless loops at runtime), heartbeat, breathing, four footstep variants,
  page rustle, apparition swell, jumpscare, win sting and UI click.

## Mobile notes

* `canvas_items` stretch with `expand` aspect; the design resolution flips to a
  portrait-friendly 720×1280 when the window is taller than wide.
* The camera switches to `KEEP_WIDTH` in portrait so you don't get tunnel vision.
* Touch UI: floating stick (left), swipe-look (right), RUN / LIGHT / TAKE buttons
  with generous 45 px+ targets, plus a dedicated pause button.
* Notes never block play — they fade, and any input dismisses them.
* Android export uses the OpenGL Compatibility renderer with ETC2/ASTC textures;
  the shipped APK is arm64-v8a (97% of devices), with arm32/x86_64 one flag away.

## Screenshots

All of these were rendered by the game itself inside headless sway:

| | |
|---|---|
| ![title](screenshots/00_title.jpg) | ![landmark](screenshots/01_page_1_walls.jpg) |
| ![silo](screenshots/08_page_8_silo.jpg) | ![apparition](screenshots/12_slender_apparition.jpg) |
| ![fence](screenshots/17_gate_road.jpg) | ![fence line](screenshots/19_fence_line.jpg) |
| ![page cloth](screenshots/10_page_cloth.jpg) | ![concrete](screenshots/11_concrete_detail.jpg) |
| ![note](screenshots/15_note.jpg) | ![touch](screenshots/16_touch_ui.jpg) |
| ![pause](screenshots/00_pause_menu.jpg) | ![death](screenshots/02_death_screen.jpg) |
| ![win](screenshots/01_win_screen.jpg) | ![close](screenshots/13_slender_close.jpg) |

Portrait phone / web build: `screenshots/mobile_web_portrait.jpg`,
touch-UI tour at phone resolution: `screenshots/mobile/`,
Chromium captures of the exported web build: `screenshots/web/`.

---

## Licence / credits

Fan tribute, not affiliated with Parsec Productions. Original *Slender: The Eight
Pages* by Mark J. Hadley. All code and procedural assets here are original and
may be reused freely. Bundled DejaVu fonts are under the Bitstream Vera licence.
