# PersonalBuffs

An Ashita v4 addon for HorizonXI that shows how much time is left on the buffs **you** cast — on yourself and on others — plus your own ability and spell recasts.

- **Author:** Renavi
- **Version:** 1.0
- **Ashita:** v4 (HorizonXI launcher)

> Code written with Claude (AI) at my direction. I tested it in game and maintain it.

## What it shows

**Buff box**
- One row per buff you cast (spells, songs, rolls, job abilities), lowest timer first.
- Click a row to see each person who has it and their own timer.
- Times shown with `~` are estimates. Times without `~` were read from your own buff list.
- Optional: your party members' casts, marked like `Haste (Name)`. **Off by default.**

**Recast box**
- Your own ability and spell recasts, read from your client. Shows "Ready" for 5 seconds when one comes off cooldown.

**Settings window (`/pb`)**
- Per-job checkboxes to hide buffs or recasts.
- Party tab: main on/off switch and a checkbox per person.
- Test mode: fake rows so you can place the windows without casting.

## How buff times are worked out

1. **Real time** – if the buff also landed on you, the time is read from your own status timers (this already counts your gear).
2. **Saved time** – the real time from an earlier cast of the same buff with the same gear setup.
3. **Estimate** – base time from `durations.lua` (from LandSandBoat) plus known gear bonuses. Shown with `~`.

Times on other people are always based on your own casts or your saved/estimated times. The addon cannot see other players' real buff timers.

## What it does NOT do

- Does **not** send packets, use commands, cast, or take any action for you. No automation of any kind.
- Does **not** change any game memory. It only reads.
- Does **not** track alliance members or strangers — party only, and only if you turn it on.
- Does **not** track Trusts.
- Does **not** connect to the internet or any outside service.

## What it reads (for reviewers)

| Source | Used for |
|---|---|
| Incoming action packet `0x028` (read only) | Seeing which buffs you (or party members, if on) cast and who they landed on |
| Your own buff list and status timers | Real time left on buffs that are on you |
| Vana'diel clock (memory pattern in `FFXiMain.dll`) | Turning your status timers into seconds |
| Your recast timers | Recast box |
| Your equipped items | Gear duration bonuses (e.g. instrument, Dilation Ring) |
| Party list | Names, and checking a caster is in your party |
| Ashita resource manager | Spell / ability / item names |

## Install

1. Download the latest release zip (or **Code → Download ZIP**).
2. Put the folder in `HorizonXI\Game\addons\` so you have `addons\personalbuffs\personalbuffs.lua`.
   The folder **must** be named `personalbuffs` (rename it if GitHub added `-main`).
3. In game: `/addon load personalbuffs`
4. To load it every time, add `/addon load personalbuffs` to your `scripts\default.txt`.

## Commands

| Command | What it does |
|---|---|
| `/pb` or `/pb config` | Open / close the settings window |
| `/pb test` | Test mode on / off (fake buffs and recasts) |
| `/pb party` | Party buff tracking on / off |
| `/pb clear` | Clear all current timers |
| `/pb hide <buff>` / `/pb show <buff>` | Hide / show a buff |
| `/pb hide recast <name>` / `/pb show recast <name>` | Hide / show a recast |
| `/pb list` | List what is hidden |

Drag the boxes to move them. Their spots are saved.

## Files

- `personalbuffs.lua` – the addon.
- `durations.lua` – base buff times by spell ID (from LandSandBoat).
- `jobdata.lua` – which job gets each spell / ability at level 75 (from LandSandBoat `spell_list.sql` / `abilities.sql`).

## Known limits

- If a buff is removed early (dispel, death, overwritten by someone else), its timer on other people keeps running until it ends.
- Times on other people are estimates unless the same buff also landed on you.
- Gear bonuses on other players cannot be seen.

## Credits

- Buff durations and job spell lists: [LandSandBoat](https://github.com/LandSandBoat/server) (GPL-3.0).
- Built for [Ashita v4](https://github.com/AshitaXI/Ashita-v4beta).

## License

GPL-3.0. See `LICENSE`.
