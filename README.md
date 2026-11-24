# HOOD Playtest: gun camera and instant replay

Two client-side, visual-only GDScript mods for the Steam game **HOOD Playtest**
(Godot 4.7). They are single-player tools. They don't change gameplay, saves or the
network protocol.

This repo contains only my own scripts. It has no game files, assets or decompiled code.

## What's in it

| File | What it does |
|---|---|
| `hood_gun_cam.gd` | Press **F8** for a camera mounted on your weapon. It can face forward or look back at you, canted, with live adjustment. |
| `hood_replay.gd` | An instant replay of the last 60 s with manual start and stop, free camera tools and a hidden HUD. |
| `override.cfg.example` | Autoload entries that load both scripts. |

### Gun camera
| Key | Action |
|---|---|
| F8 | Toggle on and off |
| F9 / Shift+F9 | Next / previous preset |
| Shift + arrows, PgUp/PgDn | Move the camera |
| Ctrl + arrows, PgUp/PgDn | Rotate and roll the camera |
| F10 | Print the offsets to the log |
| F11 | Reset the current preset |

### Instant replay
- **F6** starts or stops recording. A rolling buffer keeps the last 60 s.
- **F7** starts or stops the replay. The game is paused and the HUD is hidden while it plays.
- **F4** shows or hides the controls panel.

| Key | In replay |
|---|---|
| Space | Pause / play |
| Left / Right | Scrub 2 s |
| Home / End | Jump to start / end |
| `[` / `]` | Slower / faster (0.125x to 4x) |
| 1 | Free-fly camera (WASD, Q/E, mouse) |
| 2 / 3 | Gun camera, forward / back at the shooter |
| 4 | Orbit camera |
| 5 | First person: the player's body is hidden and the game's own arms and weapon animate |
| T | Next target character |
| Shift/Ctrl + arrows, PgUp/PgDn | Adjust the mounted camera. F10 prints the offsets and F11 resets them. |
| H | Show / hide the timeline |
| Esc / F7 | Exit |

Recorded, per character: transform, every bone pose, look direction, held item and
ragdolls. Also recorded: nearby physics bodies, vehicles with wheels and door/trunk
panels, the player's first-person view, and the effects of gunshots (tracers, sound,
muzzle flash, sparks, blood).

Known limits:
- Muzzle smoke and blood decals aren't replayed.
- Vehicle panels are matched by node name (`Door_FL`, `Trunk`, etc.).
- NPC first person is approximate.

## Install
1. Find the game's user data folder. On Proton it is:
   `<steam library>/steamapps/compatdata/5503010/pfx/drive_c/users/steamuser/AppData/Roaming/Godot/app_userdata/HOOD/`
   On Windows it is `%APPDATA%\Godot\app_userdata\HOOD\`.
2. Copy `hood_gun_cam.gd` and `hood_replay.gd` into a `mods` folder there.
3. Copy `override.cfg.example` to `override.cfg` next to `HOOD.exe` in the game folder.
4. Start the game. The log (`logs/godot.log` in the user data folder) should show
   `[GunCam] loaded` and `[Replay] loaded`.

To uninstall, delete `override.cfg`.

## Notes
- Use single-player or your own host only. These are visual tools and not for competitive use.
- The scripts were developed by inspecting the game's own scenes. GDScript parse errors
  disable the autoload, so check the log after editing.
- Assisted with AI tools.
