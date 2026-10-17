# Living Server

Part of the Social Expansion fork. The goal (Chris, 2026-10-16): make the autonomous gamebots feel
like players on a 2003 server, through continuity and consequence more than through more chat.

**Status:** built on `feature/living-server`. Automated tests pass (see "Tests" below).
**Partly checked in game** (2026-10-17, see "In-game check" below). Every part starts **off**; with
everything off the server behaves exactly as before.

Only autonomous gamebots change. Your `/spawn` companions and real players are never affected.
Lines come from the bot-voices corpus (`living_server.lines` and `memory.lines`), in each bot's
own writing style. They work whether or not "Bot voices" is on, and they are only said where a
real player can hear them (your group, `/say` near you, your realm's `/faction`, a guild with you
in it).

## Switches

All are in the launcher's **Social Expansion** tab, card **LIVING SERVER**. Save with the server
stopped; they are used at the next start. The server keys (category `bots`) are:

| Switch | Key | Default |
|---|---|---|
| Bots remember you | `bot_living_memory` | False |
| Grats | `bot_living_grats` | False |
| Server firsts | `bot_living_firsts` | False |
| Rezzes and corpse runs | `bot_living_death` | False |
| Frontier alarms | `bot_living_alarms` | False |
| Nemeses | `bot_living_nemesis` | False |
| Bot schedule | `bot_schedule_mode` | `off` (also `session`, `clock`) |
| Breaks and linkdeads | `bot_living_breaks` | False |

**ALL OFF** in the tab switches every part off, along with the other Social Expansion features.

## What each part does

### Bots remember you (`bot_living_memory`)
- A bot of your realm remembers:
  - grouping with you (noted at most once per 30 minutes per bot);
  - you rezzing it;
  - you insulting it in chat (the chat model's "abuse" intent).
- Its mood toward you follows from that: friendly, neutral, or cool after insults.
- What it does with the memory:
  - **Greets you** when you pass within about 700 units: at most one greeting every 3 minutes, and
    the same bot at most every 45 minutes. Groupmates don't greet.
  - Sometimes **thanks you for an old rez or a good group**, naming the place.
  - **Answers you by name** (most of the time) when you talk near it, in `/faction`, or by its
    name. A cool bot gives you a short brush-off. Insults and out-of-game talk keep the old replies.
  - Now and then (every 30–60 minutes per realm) a bot that likes you **mentions you in
    `/faction`**, never one standing next to you.
- Memory is chat only. It never changes who groups with whom, and it never refuses you.
- Kept in the table `offline_bot_memory`.
- Not built: memory of heals and trades. Lines for them exist but are never chosen.

### Grats (`bot_living_grats`)
When you or a bot gains a level:
- 1–3 bots in the group say grats in `/group` (only when a real player is in the group).
- Bots standing nearby say grats in `/say`: 0–2 for your dings, 0–1 for a bot's (only when a real
  player is near).
- At level 50, 1–3 bots of the realm cheer in `/faction`.

Each character gets at most one grats chain every 20 seconds. This is separate from guild grats
(bot guilds), which stay in `/gu`.

### Server firsts (`bot_living_firsts`)
- **What counts:**
  - the first character on the server, you or a bot, to reach level 50;
  - the first of each class to reach 50;
  - the first to each realm rank from 2 up.
- **How it's announced:** everyone gets one line on screen and in the system window. Other realms
  see "a Hibernian champion" (or "an Albion…", "a Midgard…"), not the name. In the achiever's realm, 1–2 bots cheer in `/faction`.
- **Recorded:** in `offline_server_firsts`, and shown in the Camelot Herald.
- **Turning it on in a played world:** titles someone already holds are marked "reached before
  records began" (no name, never announced). So the next character to get there isn't wrongly
  called the first.
  - This happens once: at the first start with the switch on, and again only if the switch was
    off in between. Bots made later with the launcher's **+ Lv.50** button never reached 50, so
    they don't take the level 50 titles.
- **Not built:** "first kill of a big named monster".

### Rezzes and corpse runs (`bot_living_death`)
- **When a bot dies:**
  - If a real player of its realm who can rez is within about 2,500 units, the bot asks that
    player for a rez by name, after a few seconds: in `/group` if you're grouped, in `/say` if
    you're close, otherwise as a `/send`.
  - "Can rez" means a Cleric, Friar, Healer, Shaman, Druid, Warden or Bard who has learned a
    resurrection spell (from the spells it lists, or a resurrection spell in its spell lines at
    or below the line's level).
  - The bot's corpse stays where it died until it releases, so it can be rezzed there.
  - With nobody who can rez near, a bot sometimes asks generally ("rez pls?", "anyone able to
    rez, dead by the spirit hound") in `/group`, or in `/say` when you're close.
  - The bot then waits the long release timer (90 s) instead of 20 s, even if you aren't in its
    group.
- **Releasing and being rezzed:**
  - A bot that releases may say it's running back from bind.
  - A bot in your group sometimes grumbles about resurrection sickness. Bots don't actually get
    the illness; this is chat only.
  - A rezzed bot thanks the rezzer by name. This replaces the old "My thanks... formation" lines
    for autonomous gamebots.
- **Bots rez you:**
  - An autonomous gamebot that can rez, and isn't in your group, rezzes you when you lie dead
    within 1,500 units of it.
  - You get the normal accept/decline box. Once a box from a bot closes, no bot offers again for
    about 90 seconds.
  - It never rezzes during a fight (its own or its group's), or with hostile monsters within about
    700 units of you. Only one bot works on a corpse at a time.
  - A bot on a siege job, holding a siege position, carrying a relic or in an RvR event force
    doesn't come. A bot that can't reach you within 20 seconds gives up on you for 2 minutes.
  - Groupmates already rezzed you before; that is unchanged.
- **Server log:** every ask is logged as `LIVING_SERVER_REZ_ASK` (with who could have rezzed),
  every rez a bot starts on you as `LIVING_SERVER_REZ`, and a rez bot near your corpse that
  doesn't rez says why as `LIVING_SERVER_REZ_SKIP` (at most every 15 seconds per bot).

### Frontier alarms (`bot_living_alarms`)
- **When:** a bot in the frontier or a battleground sees 3 or more enemy players or gamebots
  during its normal threat scan. It calls them in `/faction`, for example "inc 8+ mids at Caer
  Benowyc, healer, warrior, skald".
- **What it says:**
  - the head count is rough (exact below 10, then 10, 15, 20);
  - up to three classes;
  - the place is the nearest frontier keep within 6,000 units, or the zone.
- **Limits:** at most one alarm per realm every 2 minutes, and one per place every 5 minutes. None
  while a `/faction` debate is running.

### Nemeses (`bot_living_nemesis`)
- **Recording:** a bot killed by an enemy player or enemy gamebot records the killer (pets count
  for their owner) in `offline_bot_nemesis`.
- **Complaining:** from the second kill by the same enemy, the bot may complain in `/faction`,
  once per 20 minutes at most.
  - Enemy names are hidden in the frontier, so it names the killer by race and class: "that troll
    berserker is camping Caer Benowyc".
- **Revenge:** when the bot later kills that enemy, it may gloat in `/faction`.
- **Herald:** the Camelot Herald's **Most Wanted** lists the enemies with the most recorded kills.
- **Size:** each bot remembers at most 8 killers (a new one replaces its least-deadly one), and
  with this switch on, one-kill rows older than a week are forgotten at server start.

### Bot schedule (`bot_schedule_mode`)
- `off` (default): every bot stays online, as before.
- `session`: each bot plays sessions of 1–4 hours, with 20 minutes to 2 hours away. Timing is
  counted from server start. About two-thirds of the roster is online at any time.
  - No-lifers play longer and are away less; Socialites play a little longer.
- `clock`: follows your PC's clock like a 2002 North American server.
  - About 95% of the roster is online from 8 to 10 p.m.
  - About 20% at 4–5 a.m.
  - Weekends (from Friday 6 p.m.) are busier in the daytime.
  - The same bots stay on as the evening fills up; no-lifers stay up late.

**How logging out works:**
- Only bots that can leave without breaking anything log out: ungrouped, alive, out of combat, not
  casting, not on a stable route, not walking back after a release, not carrying a relic, not on a
  siege job and not in an RvR event force. A scheduled-off bot that is busy stays until it's free.
- At most 3 bots log out every 5 seconds.
- A bot may say goodnight first: in guild chat when a guild member can hear, otherwise in `/say`
  near you.
- Scheduled-off bots aren't logged back in until their schedule says so. When they return, some
  say hello. Nobody greets during the first 10 minutes after the server starts.
- Busy scheduled-off bots (often in a bot group) stay online until they're free. For their first
  15 minutes they count against the schedule, so logins wait for them (with 10% slack); after that
  they no longer hold back the bots whose turn it is, so the total can run above the schedule's
  number for a while, but never more than a quarter above it.

### Breaks and linkdeads (`bot_living_breaks`)
- **Breaks:** an idle bot (the same rules as logging out) now and then says "brb" and logs off for
  5–25 minutes, about once per 4 hours online. When it comes back it says "back".
- **Linkdeads:** a bot in a group with you rarely goes linkdead.
  - How often: at most once per group every 45 minutes; on average about once every hour and a
    half of grouping.
  - What happens: it stands still and does nothing for 30–90 seconds. Another bot in the group may
    say "X went ld", and the bot comes back with "sry ld".
  - Never during a fight: it wakes at once if anyone in the group fights, if it's attacked, or if
    the group breaks up. Bots on a stable route, a siege job, a relic or an RvR event force never
    go linkdead.

## New client (0.36c)

Everything here runs in the server and the launcher, so it works the same with the original client and the Godot
client. Checked on 2026-10-17 with `tools/newclient-compat` (network level, no game world): the Godot client's own
network code and interface received every Living Server chat line and both yes / no boxes from the server's own
packet code. Every line landed in the right channel and chat box, server firsts showed on screen, and the server
read the ACCEPT answers. Result: 30 of 30 passed.

One gap is the Godot client's, not this build's: it has no guild window yet, so a bot guild's member list can't be
browsed there. Guild chat, guild names over heads and the invite box work.

## Camelot Herald

**CAMELOT HERALD** in the Social Expansion tab writes a news page from the game database and
opens it in your browser. It reads only and is safe while the server runs.
- **Where:** one self-contained file at `runtime\herald\herald.html`. Nothing is loaded from the
  internet.
- **What it shows:** realm points leaders, guilds, keeps held by enemies, relics, server firsts,
  Most Wanted, and recent realm events.
- **Releases:** the page names your characters, so the release builder never ships the `herald`
  folder.

## Data and releases

New tables, all empty in a release and carried by the progress transfer when both databases have
them:
- `offline_bot_memory`
- `offline_bot_nemesis`
- `offline_server_firsts`

Writes are batched off the game loop every 5 seconds, under the same database lock as bot status
saves. The release builder deletes every `bot_living_*` setting and `bot_schedule_mode`, so
releases ship with everything off.

## Tests

Automated (no running world):
- **Server, `UT_AutonomousLivingServer`:**
  - defaults are off;
  - schedule parsing, session lengths and online share, and how often a bot's state changes;
  - the clock curve and that clock mode keeps the same bots online;
  - mood rules, alarm head counts, race and realm words, first claims;
  - tables save changes and deletions to a real SQLite file and load them back;
  - nemesis and alarm lines fill every slot; greetings follow mood;
  - this document lists every key.
- **Server, `UT_AutonomousBotVoices`:**
  - every Living Server kind has lines for every personality;
  - topic filtering;
  - the six-hour no-repeat window.
- **Launcher:**
  - `SocialExpansionSettingsTests`: the new keys and defaults match the server, the schedule mode
    is read like the server reads it, and ALL OFF;
  - `HeraldPageTests`.
- **Corpus:** `build_corpus.py --verify` and `check_runtime_names.py` in CI.

## In-game check (2026-10-17)

Played on the owner's PC with build 0.36-chris.3 in the Godot client (0.36c), all eight switches
on, schedule `session`, 50 bots made with the launcher. About two hours, an Albion Cleric.

**Seen working in game:**
- **Grats:** on a ding with two bots in the group: `[Party] Hareralfrey: "gratz"`,
  `[Party] Maraenisette: "grats Claudecheck, go train :P"`.
- **Server first:** reaching realm rank 2 put "Server first: Claudecheck is the first on the
  server to reach realm rank 2" on screen and in the system window. Two bots cheered in `/faction`.
- **Memory:** grouping was saved within seconds (`offline_bot_memory`). A former groupmate passing
  by said "had fun at Camelot Hills with you Claudecheck, again sometime? :P", and later "Claudecheck!
  we should group again sometime".
- **Rezzes:** a groupmate that died asked in `/group` "anyone able to rez, dead by the spirit
  hound", then after releasing said "long run back to Camelot Hills :)".
- **Schedule:** bots logged out (one said "gn all" in `/say` beside me, out of combat) and came
  back about 25 minutes later. The server log has 10 `LIVING_SERVER_LOGOUT` lines in two hours,
  two of them breaks (`reason=brb`); I wasn't near those two, so their "brb" wasn't seen in chat.
- **Nemesis:** a Hibernian Enchanter killing an Albion bot at Hadrian's Wall was saved with race,
  class and place.
- **Camelot Herald:** the page listed the server first, the realm point leaders and Most Wanted
  (two Midgard bots with two kills each).

**Bugs found and fixed after this check:**
- A bot that knew you answered by name only about one time in five: its known-player replies were
  mixed with the general replies. They now have their own topic, and there are known-player
  replies for every ordinary intent (test `ARememberedPlayerIsAnsweredByNameForEveryOrdinaryIntent`).
- Every server start re-seeded the "reached before records began" titles, so bots made at level 50
  with the launcher took "first to level 50" and all the class titles. Seeding now happens once
  (test `FirstsAreSeededOnceSoBotsMadeAtFiftyLaterDontTakeThem`).

**Not seen in the first check** (both fixed and then seen in the second check, below):
- A bot rezzing me. Four tries near a level 50 Friar or Cleric: one bot was logged out by the
  schedule, one stayed in a fight, and two walked on while travelling.
- A bot asking me for a rez by name. With my level 50 Cleric (Revive learned) beside a bot that
  died, no ask came.
- Frontier alarms, the nemesis complaint and revenge lines, the "brb" line and linkdeads: not
  seen in two hours. They need a frontier fight, repeated kills or an hour or more in one group.

**Second check, builds 0.36-chris.5 to chris.8** (same PC, Godot client, schedule `off` so the
level 50 healers stayed online). The new log lines found two causes:
- **"Can rez" was false for a Cleric 50 with Revive.** It only looked at the spells the client
  lists, and those didn't include Revive. It now also checks the character's spell lines for a
  resurrection spell at or below the line's level (chris.5). The log then showed `can_rez=True`.
- **A dead gamebot's corpse moved to its spawn point within milliseconds.** When a bot dies its
  brain stops, and stopping a brain sent the body "home". `LIVING_SERVER_DEAD_MOVE` showed
  `by=ABrain.Stop deadMs=33`. So the bot asked for a rez from a corpse that was no longer beside
  you, and no player or bot could reach it. This probably also broke bot-to-bot rezzes in bot
  groups before this branch. A dead gamebot now stays where it died. Its release still moves it
  to its bind, at 20 s (or 90 s when someone near can rez), and a rezzed bot's brain starts again
  (chris.8).

Seen in game with chris.8:
- **A bot asks me by name:** a level 4 Friar that died 655 units from my Cleric sent "Claudecheck
  rez pls?". The log has `LIVING_SERVER_REZ_ASK ... rezzer="Claudecheck" died_at=... now_at=...`
  with the same position twice. The corpse stayed there for the full 90 s, then released.
- **Every other bot death** in that session also kept its corpse in place until the release at
  21 s. No `by=ABrain.Stop` moves were logged.
- **A bot rezzes me:** I died beside a level 50 Cleric bot that wasn't in my group. It said "rez
  incoming", the log has `LIVING_SERVER_REZ bot="Seraorith" corpse="Claudecheck" distance=6`, and
  the accept box appeared. My first accept came after the stock 15-second offer had expired.
  About 90 s later it offered again ("got you Claudecheck, one sec lol"); I accepted and was
  rezzed.

Not checked: a player rezzing a dead bot, and its thank-you line. In the Godot client, Revive had
no target ("You must select a target for this spell!"). Whether the client clears the target or
hides the corpse is **not confirmed**: I click slowly, and a dead bot's corpse was visible in the
2026-10-17 play session. The original client wasn't tried.

**Godot client gaps seen** (the client's, not this build's):
- The FACE, FOLLOW and STICK buttons sent `/face`, `/follow` and `/stick`, which the server
  doesn't have. **Fixed in chris.10** and checked in game.
- The client ignored the server's ChangeTarget packet, so `/target <name>` and `/assist` never
  changed your target. **Fixed in chris.10** and checked in game with `/target Rhuz`.
- Targeting a corpse to rez it: not confirmed (see above).

**Third check: a play session, build 0.36-chris.9** (2026-10-17, 14:17 to 15:37, Godot client).
All eight switches were on, the schedule was `session`, and each realm had 300 bots (150 at level
1, 150 at level 50). I played Claudecheck (GM, Cleric 50) and judged results from the server log
rather than my own reaction times.
- **Seen working:**
  - Two debates played to the end. Each waited once for a busy speaker (`BOT_DEBATE_WAIT`), so the
    chris.9 wait is now seen in game. The second started 36½ minutes after the first ended.
  - 9 frontier alarms in `/faction`, such as "11 hibs at Nottmoor Faste".
  - 52 "brb" breaks and 218 session logouts.
  - 87 new nemesis records, one kill each; no revenge yet.
  - Bot memory: Maraenisette remembered grouping with me (Grouped=3), and gossiped about me by
    name in `/faction`.
  - Maraenisette joined my group, followed me and buffed me.
  - No errors after start.
- **Not seen:** a linkdead, nemesis chat lines, a keep claim, and me rezzing a bot.
  - Linkdeads roll only for bots in your own group (1 in 90 every 30 s, then 45 minutes'
    cooldown). I was grouped for about 30 minutes, so not seeing one is about a coin flip.
- **Found and fixed in 0.36-chris.10** (pull request #8). Checked in game afterwards unless
  marked otherwise:
  - **Tells to bots.** Bots say "pst me" (38 corpus lines), but `/send <bot>` answered "not in the
    game". A tell now reaches an online bot of your realm, and it answers with a `/send`. "hey,
    how is it going?" got "hey good to see someone else out here".
  - **Join requests.** Players lead and bots join, so a tell asking to join is answered with
    "invite me", or "meet up and inv me" when the bot is far away.
  - **Invite by name.** `/invite <name>` found only companion bots. It now invites a nearby
    autonomous bot (same region, within 6,000 units). Farther away it says "too far away to join
    you. Meet up first."
  - **Target by name.** `/target <name>` now finds a same-realm bot nearby, for players too.
  - **The new client's target buttons.** See "Godot client gaps seen" above.
  - **A second `/stick` or `/follow`** on the same target now turns it off, as in the old client.
    (Checked with FACE, which uses the same code: "now facing", then "no longer facing".)
  - **Guild gossip.** "we should get Claudecheck into a guild" was said while I was in a bot
    guild. It is now said only about a player with no guild; a starting guild counts as none.
    (Unit test only: gossip comes about once every 30–60 minutes.)
- **Found, not fixed (stock 0.36 code, not Living Server):**
  - **A group can die on its way to a meetup.** A Midgard group of five bots, levels 1 to 3, spent
    the full 15-minute meetup wait dying near its meetup point: about 70 deaths in all. Then it was
    dropped as no-shows. `AutonomousRendezvousAttendance` waits 15 minutes and has no limit on
    deaths along the way.
  - **"lfg" gets answers like "we have room for 3"**, but bots never invite players.

Suggested checks that remain:
1. Turn on **Grats**, group with bots and level: groupmates say grats in `/group`.
2. Turn on **Rezzes and corpse runs** on a rez class, in the original client: rez a bot that
   asked you by name, and it thanks you. (The ask and a bot rezzing you were seen with chris.8.)
3. Turn on **Bots remember you**: group with a bot for a while, leave, and walk past it later. It
   greets you by name.
4. ~~Frontier alarms~~: seen in the chris.9 play session (9 in 80 minutes).
5. Set **Bot schedule** to `clock` and start the server at different times of day: the online
   count in the launcher follows the time.
6. Turn on **Breaks and linkdeads** and group with bots for an hour: watch for "ld". ("brb" was
   seen in the chris.9 play session.)
7. Click **CAMELOT HERALD**.
