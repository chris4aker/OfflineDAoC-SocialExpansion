# Bot personalities, voices and debates: design and status

Goal: autonomous gamebots that feel like different people. Some grind, some hang around town, some
go looking for trouble, and each one writes in its own style. These are the "Social Expansion"
features, alongside [BOT-GUILDS.md](BOT-GUILDS.md).

They affect only **autonomous gamebots**. Companion bots (`/spawn`, `/raid`) and real players keep
today's behavior. Every part ships **off**. With all of it off, bots behave exactly as in stock 0.36.

## 1. Switches

| Setting (`ServerProperty`, category `bots`) | Default | What it does |
|---|---|---|
| `bot_personalities_enabled` | False | Personality types and traits tilt how bots spend their time (section 2). |
| `bot_voices_enabled` | False | Bots say lines from the bot-voices corpus in their own writing style (section 3). |
| `bot_voices_debates` | True | When voices are on, bots hold debates and long threads in /faction (section 4). |

To change them, use the launcher's **Social Expansion** tab (with the server stopped; it applies at the next start). The same switches are in a script, for those who prefer it: close the
server, launcher and game, then run (Python 3):

```
python tools\claude-version\set_bot_social.py                       (show the settings)
python tools\claude-version\set_bot_social.py --all on --apply      (all three on)
python tools\claude-version\set_bot_social.py --debates off --apply (one part off)
python tools\claude-version\set_bot_social.py --all off --apply     (back to stock behavior)
```

Without `--apply` the script only shows what it would change. With `--apply` it backs up the
database first (`runtime/server/deployment-backups/bot-social-<time>`) and reads the values back.

In game, target an autonomous bot and type `/personality` to see its type, traits and voice.

## 2. Personalities

A bot's personality is fixed from its database id, so it never changes between logins and
needs no new saved data.

### 2.1 Types

| Type | Share | In short |
|---|---|---|
| Leveler | 28% | grinds, short town breaks, likes full camps, often goes solo |
| Socialite | 20% | long town breaks, wants groups, chatty |
| Daredevil | 20% | dungeons, the harder cons of its legal range |
| Explorer | 16% | new zones, prefers solo |
| Crafter | 12% | long town breaks, avoids RvR, easy camps |
| NoLifer | 4% | barely stops, wants groups, dungeons |

Each bot also has five traits from 0 to 9 (curiosity, risk, sociability, patience, chattiness),
drawn within its type's range, so two Daredevils still differ.

### 2.2 What a personality changes

Every change is a **tilt** on a choice the bot already makes. The owner's hard rules (legal camps,
level ranges, real loot, selling only at natural breaks, earning armor, DF open to solo bots) are
never bypassed.

| Choice | Today | With personalities |
|---|---|---|
| Town break at a task boundary | 15% for every bot | about 4–37.5% by type, scaled by sociability (the realm average is about 16–17%) |
| Town break length | 15–30 minutes | ×0.7 (Leveler, NoLifer) to ×1.5 (Socialite), at least 5 minutes |
| Goal (solo, group, RvR...) | the allocator fills the mix's slots with bots in random order | the mix still decides **how many** bots get each goal; personality decides **who** (below) |
| Dungeon or outdoors | the configured dungeon preference | 60% (Crafter) to 170% (Daredevil) of it; a group uses its leader's |
| Which outdoor camp | weighted by live spawns | also weighted by taste: Daredevils like yellow and orange cons, Explorers like zones they haven't visited in 6 hours, Levelers like full camps. Every legal camp keeps at least 10% weight |
| How often it chats | the normal rate | ×0.25 to ×1.56 by chattiness (the realm average stays about the same) |

Zone memory is kept in memory only (32 zones per bot, forgotten when the server restarts).

**Goals (changed 2026-10-17).** Before this change, personality only tilted goals when a Bot Goals file existed, and
only for bots reassigned outside the allocator's pass, so it barely mattered. Now, each time the allocator hands out
goals to the bots of a realm and level band, it plans the open slots together:
- Battleground slots go first (only bots of a bracket's levels can take them), then RvR to the bots that want it
  most compared with their other choices, then groups versus solo.
- It is a weighted draw, so nothing is forced or banned, and it works with or without a saved Bot Goals setting.
- The mix's open slots are filled exactly (`AutonomousBotPersonality.PlanGoals`). The planned bots are assigned
  first, so bots beyond the open slots can't take a planned bot's slot; they then get a goal by the allocator's
  usual over-quota rule, as before.

In a test of 1,000 bots with a 40% solo, 40% group and 20% RvR mix:

| Type | Solo | Group | RvR |
|---|---|---|---|
| Leveler | 62% | 31% | 6% |
| Socialite | 1% | 88% | 12% |
| Daredevil | 21% | 28% | 52% |
| Explorer | 61% | 21% | 19% |
| Crafter | 70% | 25% | 5% |
| No-lifer | 3% | 47% | 50% |

Personality doesn't choose goals in two cases:
- A bot given a new goal between passes (for example when its group breaks up) uses the older re-draw rule, and
  only when a Bot Goals setting is saved.
- A bot left over once every open slot in its pass is filled gets the allocator's usual over-quota goal.

## 3. Voices

When voices are on, a bot's chat comes from the corpus in
`source/server/GameServer/bots/autonomous/data/chat/` (842 lines and 296 scenes, written for
2002–2003; see [bot-voices/DESIGN.md](bot-voices/DESIGN.md)). The corpus is built into
`GameServer.dll`. Nothing is generated freely.

**Choosing a line:**
- by kind (ambient, lfg, trade, rvr, camp, reply, ding, death), realm, class, level and situation
  (in a group, solo, in town, in a dungeon, in RvR, at a camp, traveling, just leveled, just died,
  bag full)
- lines written for a personality type are three times as likely for that type and never used by
  other types
- replies to you match the intent the chat model reads from your message
- no line is repeated in a realm within 6 hours

**Writing styles** (fixed from the bot's id): plain 35%, terse 25%, chatty 20%, proper 15%,
typo-prone 5%.

**Where voices are heard:**
- ambient chat that a bot starts, in /say or /faction
- bot replies to players and to other bots (directed questions and knowledge answers keep today's
  answers)
- "ding" (35% chance) and death (25% chance) lines in /say, only when you are nearby

When no corpus line fits, the bot uses its old line.

**Not done yet:** lines that name you, a place you met or your class (`{player}`, `{place}`,
`{player_class}`) need bot memory of the player. Those lines are skipped for now. The greet,
thanks, gossip and grudge lines are in the corpus but not used yet.

## 4. Debates and long threads

When voices and debates are on, each realm's bots play scenes from the corpus in /faction:
- one scene at a time per realm, 30–45 minutes apart, the first 5–10 minutes after the server
  starts
- only while a player of that realm is online
- the cast is chosen from online bots of the realm within 5 levels of the scene's band, with a
  role's required class always kept and its personality type preferred
- a scene starts only if every required line can be said (a "price check" scene doesn't start when
  its speaker carries nothing)
- 3–10 seconds between lines, like typing
- if a speaker goes into combat, dies or logs out, another fitting bot takes the part, or the line
  is skipped; with fewer than two speakers left, the scene ends
- no scene repeats in a realm until all of its fitting scenes have played. The heard list is saved
  in `offline_bot_scenes_heard`, so it survives restarts. The release builder empties this table.

While a scene runs, bots don't start other /faction chatter in that realm.

## 5. Status

**Automated tests** (`UT_AutonomousBotPersonality`, `UT_AutonomousBotVoices`) cover:
- the type shares and the trait ranges
- the tilts and their averages
- the corpus loading from the DLL
- slots, tags, era words and lengths
- line choice, writing styles and the no-repeat window
- debate casting, scene choice and pacing

**Partly checked in game** (2026-10-17, build 0.36-chris.8, Godot client, about 20 minutes):
- **`/personality`** on Maraenisette (id 6) gave "Socialite (curiosity 4, risk 3, sociability
  7, patience 5, chattiness 9); writes chatty".
  - A Python copy of `AutonomousBotPersonality.For` gives exactly that for id 6.
  - Over the 50-bot roster it gives every type: Leveler 18, Daredevil 9, Explorer 9,
    Socialite 7, Crafter 6, NoLifer 1. The variety comes from that calculation; only one bot
    was read in game.
- **Debate:** `BOT_DEBATE_START scene=camp_etiquette speakers=3` 5½ minutes after start. It
  showed in `/faction` ("someone just walked into our camp and started pulling haha", "first
  come first served, that is the rule", "just invite them more ppl more xp", "and if the group is
  full?"). It ended after 24 s with "fewer than two speakers left", so it was cut short.
  - **Why:** a speaker had to be free (not fighting or casting) at the exact moment its line was
    due. Two of the three level 4–5 bots were mid-fight at 12:35:42; one died seconds later.
  - **Fixed in 0.36-chris.9:**
    - A busy speaker is waited for (retried every 5 s, up to 45 s), then a stand-in takes the
      line, or the line is skipped.
    - The thread ends early only when fewer than two of its speakers are still in the world.
    - Casting prefers bots on a town break.
    - The log has `BOT_DEBATE_WAIT`.
    - Tests: `DecideBeat_WaitsForABusySpeakerAndEndsOnlyWhenSpeakersAreGone`,
      `Cast_PrefersBotsOnATownBreak`.
  - **In game with chris.9 (300 bots per realm):** `alb_armsman_three_weapons` started 7½
    minutes after start with 5 speakers. It played to the end in 3½ minutes
    (`reason="finished"`): the armsman polearm / two-hander / crossbow argument, ending "Ok I
    will just flip a coin at the trainer." No speaker was busy, so `BOT_DEBATE_WAIT` didn't
    happen.
  - **Play session with chris.9** (80 minutes): `alb_wizard_lines` (5 speakers) and
    `soc_dragon_points` (6 speakers) both finished. Each logged one `BOT_DEBATE_WAIT` for a busy
    speaker before going on, so the waiting path is now seen in game. The second debate started
    36½ minutes after the first ended, inside the 30–45 minute window.
- **Lines:** about 25 voice lines in `/faction`, `/say` and `/gu` fit the moment, in period
  style, with no `{` or `}`.
- **Not checked:** how busy towns are compared with stock, how often lines repeat over hours,
  and ding or death lines from voices.

Things to watch in a longer session:
- towns busier or emptier than in stock 0.36
- bots stuck re-drawing goals
- debates that talk over each other
- lines that don't fit the moment
