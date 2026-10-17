# Audit and release plan (2026-10-12)

What was built on Chris's fork (`chris4aker/OfflineDAoC`) on 2026-10-11 and 2026-10-12, what state
each piece is in, and the plan to code, test, install and release it.

**New development stops here** until this release is played and fixed.

**Update (2026-10-16): the release moves to 0.36.** shadowofze published 0.36 / 0.36b / 0.36c on
2026-10-16 (tags `v0.36`, `v0.36b` and `v0.36c` all point at `d88b7b2`). Stage 8 is done ahead of
the first release:

| Fact | Status |
|---|---|
| Branch `release/0.36-chris.1` = `release/0.35-chris.1` merged onto tag `v0.36`. Its build name is `0.36-chris.1`. | done |
| Merge: 3 files conflicted only because upstream switched their line endings (`BotBrain.cs`, `GameBot.cs`: CRLF → LF; `AutonomousBotGroupCoordinator.cs`: LF → CRLF). Re-merged with matching line endings: no real conflicts. Every Social Expansion hook is still in place. | verified (diff against `v0.36`) |
| 0.36 replaced the release builder. Our clean-up (bot guilds, their settings, Social Expansion switches, XP by level, alliances) is ported from `build_release_035.py` into `build_release_036.py`. | done; not run on a real 0.36 database here |
| The installer now only accepts **0.36 / 0.36b** (with or without the 0.36c new client), and also waits for the new client and its launcher to be closed. | done; real Windows install untested |
| Upstream 0.36 does not touch bot guilds, bot chat or personalities. It does raise **quest XP 3–6× for levels 21–40**, which adds to the XP-by-level plan's pace (stage 4 numbers are for kills). | verified (0.36 changelog and code) |
| The 0.36c new client runs the same server, so it gets these features too. Not tested with it. | inference |

From here on, read **0.35** in the stages below as **0.36b**, and `0.35-chris.N` as `0.36-chris.N`.
Stage 8 now applies to 0.37.

**Scope change (Chris, 2026-10-12):** the release waits for bot personalities, voices and debates,
and ships everything together as the "Social Expansion". Those were built after this audit; see
the workstream table and stage 5b.

## 1. Audit

### 1.1 Base

| Fact | Status |
|---|---|
| Fork `main` is `d121209`. Its `source/` is identical to the **v0.35 / v0.35b** release tag (`d337d18`). | verified (git diff) |
| shadowofze's newest commits (to `1cabc77`) are **changelog text only**. The 0.36 code (DXVK client, quest rewards, DF raid fix) is "local, not released yet" and isn't in the repo. | verified |
| A server built from our branches therefore matches a **v0.35 or v0.35b install**. 0.35 and 0.35b share one server build; the edition is a database setting. | verified (same tag, same source) |

### 1.2 Workstreams

| Workstream | Branch | What exists | Automated tests | In game | In this release? |
|---|---|---|---|---|---|
| XP rate by level range | `feature/xp-by-level-range` | Code, helper script `set_xp_by_level.py`, release and transfer clean-up, doc | Green | **Not tested** | Yes, off until set |
| Bot guilds, phases 1–6 | `feature/bot-guilds` | Formation, chat, recruiting you, grouping, keep claims and defense, dues, merit, buffs, alliances; helper `set_bot_guilds.py`; doc | Green (95 tests) | **Not tested** | Yes, off until turned on |
| Bot voices: data | `feature/bot-voices` | Research brief, design, corpus (842 lines, 296 scenes), build and preview tools | Corpus checker passes | n/a | Yes, as the voices' data |
| Bot personalities, voices and debates | `feature/bot-personalities` | Types and traits that tilt town breaks, goals, dungeons, camps and chattiness; the corpus embedded in the server with writing styles; /faction debates; `/personality`; helper `set_bot_social.py`; doc `BOT-PERSONALITIES.md` | Personalities green (2,788 tests); voices and debates tests added | **Not tested** | Yes, off until turned on |
| Living-world planning | `living-world/trade-sim` | Roadmap, audit, data check, Kirstena's Atlas check, trade, persona and RvR simulators | n/a | n/a | No (planning) |
| CI (GitHub Actions, Windows) | on every branch | Build, launcher, full server tests, feature test counts | n/a | n/a | Yes (tooling) |

### 1.3 Combined check (verified 2026-10-12)

- **Merge:** the three feature branches merge onto `main` as `integration/next`. The only conflict
  is the CI workflow file, which each branch added; it's resolved there.
- **CI on the combined code:** **2,769 of 2,769** server tests pass, 142 of them for these features
  (run 38264451720).
- **Release clean-up:** run on a copy of the 0.35 world database seeded with played state from
  both features: bot guilds, alliances, keep claims, guild bank and merit, the bot guild settings
  and both XP settings. All were cleared, and the builder's own verification passed.
- **Bot-voices corpus:** not embedded (the server project lists embedded files one by one). It
  doesn't change the build.

### 1.4 Findings to fix before release

| # | Finding | Severity | Fix |
|---|---|---|---|
| 1 | No downloadable server build. CI compiles and tests but publishes no `GameServer.dll`, and your PC has no build tools yet. | blocks release | CI **package** job: a zip with the Windows `GameServer.dll`, an install script and a rollback script |
| 2 | No safe install path. AGENTS.md requires deploying only tested output, with a backup, to `runtime/server`, `runtime/server/lib` and `runtime/server/win-x64`. | blocks release | `install-server-build.ps1`: refuses while the server, launcher or game runs; checks it's a 0.35/0.35b install; backs up all three copies; copies and verifies hashes. `rollback-server-build.ps1` restores the backup. |
| 3 | No way to tell which build is running. | medium | The server logs one line at startup: build name, git commit, and which features are switched on |
| 4 | Bot guild formation runs on a background timer thread, not the game loop. It creates guilds and their ranks there. It's the same pattern as phase 1 used, and low risk, but it's the one threading shortcut in the new code. | low | Move guild creation onto the game loop (as alliances already are) |
| 5 | Nothing has been played. Every result so far is an automated test. | — | Stages 3–5 below |
| 6 | Stale branches: `living-world/roadmap` and `ci/github-actions`. Everything in them exists in newer form elsewhere (verified). | housekeeping | Delete, with your OK |

## 2. Plan

Each stage ends with a check. Nothing moves on until the check passes.

### Stage 1: package and safety tooling (Claude, from here)

1. **Release branch:** turn `integration/next` into `release/0.35-chris.1`.
2. **Fixes:** findings 3 and 4 above.
3. **Package and install tooling:** the CI package job and the install/rollback scripts (findings 1 and 2).
4. **Run CI.**
   - **Automated checks:** full tests green; the zip artifact exists. The install script is
     checked against a fake install folder.
   - **Can't be tested here:** the real Windows install. That's stage 3.

### Stage 2: your PC (Chris, about an hour)

1. **Install the game:** download **Offline DAoC 0.36b** (or 0.36) from shadowofze's releases
   with the `DOWNLOAD-AND-PLAY` script.
2. **Play a baseline:** 30–60 minutes of the stock game, so you know what normal looks like:
   bots in towns and at camps, chat, a group.
3. **Optional:** open this chat in the Claude desktop app on that PC, so it's linked and Claude can
   read logs and run the install with you.

### Stage 3: install our build and smoke test (together)

1. Close the server, launcher and game.
2. Download the zip from the CI run (GitHub → Actions → the run → Artifacts).
3. Run `install-server-build.ps1`. It backs up first.
4. Start the server as usual and log in.
5. **Pass when:**
   - the startup line shows `0.36-chris.1` with every feature off;
   - the launcher has a **Social Expansion** tab, everything in it is off, and it locks while the
     server runs (also in the new client's launcher, on 0.36c);
   - there are no new errors in the log;
   - the game plays exactly like the baseline.
6. **On a failure:** run `rollback-server-build.ps1`, then send Claude the log.

### Stage 4: XP by level range

1. **Set the plan's rates:** with the server stopped, in the launcher's **Social Expansion** tab set
   both XP rows to **Suggested** and click **Save settings**. (Script alternative:
   `python tools\claude-version\set_xp_by_level.py --player "1-19:3;20-34:5;35-50:12" --bots "1-19:1.5;20-34:2.5;35-50:6" --apply`.)
   This is the goal from the roadmap's model v4: keep levels 1–34 worth playing, and compress the
   35–50 grind.
2. **Check in game:**
   - At about level 10, kill a few blue or yellow monsters: the XP should be about 3× the baseline.
   - On a character in the 20s it should be about 5×.
   - Above 35 (a /level GM character is fine) it should be about 12×.
3. **Turn it off:** both rows back to **Off**, then **Save settings**.
4. **Pass when** the numbers match.

### Stage 5: bot guilds

1. **Turn on:** with the server stopped, tick **Bot guilds** in the **Social Expansion** tab, save, start,
   and wait 10 minutes.
2. **Work through the checklist** in `docs/BOT-GUILDS.md` §4 in order:
   1. guild names over bots;
   2. "lf guild" → dialog → join;
   3. `/gu` replies, greetings and congratulations;
   4. 30 minutes of guild chat;
   5. `/gc info` bank and merit;
   6. a keep claim;
   7. alliance chat;
   8. `/ginvite` and `/gc remove` on a bot.
3. **Watch for:** chat floods, lag, or bots stuck forming groups.
4. **If one part misbehaves,** untick just that part in the tab (for example keep claims) and note it.
5. **Pass when** the checklist is complete with no blocking problem.

### Stage 5b: personalities, voices and debates

1. **Turn on:** with the server stopped, tick personalities, voices and debates in the **Social
   Expansion** tab, save, start, and play for an hour.
2. **Check:**
   1. `/personality` on a few bots: types and writing styles vary.
   2. Towns: about as busy as the baseline; some bots linger, some barely stop.
   3. /faction and /say: lines vary, fit the moment and sound like 2003; no `{` or `}`.
   4. A "ding" or death line from a bot near you, now and then.
   5. A debate in /faction within about 10 minutes of starting, then one every 30–45 minutes.
3. **Watch for:** repeated lines, debates talking over other chat, bots idling in town too long.
4. **If one part misbehaves,** untick just that part in the tab and note it.
5. **Pass when** the checks hold with no blocking problem.

### Stage 6: fix round

1. **Fix:** each problem found is fixed on its feature branch, then merged into the release
   branch.
2. **Build:** CI builds a new zip (`0.36-chris.2`, …).
3. **Retest** only the affected checklist items.
4. **Repeat** until stages 3–5b pass.

### Stage 7: release

1. **Merge:** pull request `release/0.36-chris.N` → `main`, with your approval.
2. **Tag:** `v0.36-chris.N` on your fork.
3. **Publish:** a GitHub Release with the zip, with your approval.
   - **Choice:** your fork is public, so the release would be too; a draft release keeps it to you.
   - **Contents:** only the server build (built from the GPL source) and the scripts; never a
     database, account, logs or rosters.
4. **Changelog** entry in the fork.

### Stage 8: keeping up with shadowofze

**Done for 0.36 on 2026-10-16** (see the update at the top). **When 0.37 code is published:**
1. Merge it into `main`.
2. Rebuild the release branch and rerun CI.
3. Repeat stage 3's smoke test on a 0.37 install, then release `0.37-chris.1`.

**Don't** install a 0.36-based build over a 0.37 install: it would roll back his 0.37 server
changes. The installer refuses it.

**Optional:** a weekly scheduled check for new shadowofze commits.

### After the release: the next coding project

**Bot memory of you** (bot-voices step 3), with Chris's OK: greetings by name, thanks for a rez,
gossip and invites. It also unlocks the corpus lines that are skipped today. After that, the
living-world population work (M1).

**Living Server (2026-10-16):** built on `feature/living-server`. It covers Chris's six "feel like
2003" ideas (grats and server firsts, death economy, frontier alarms, Camelot Herald, schedules and
linkdeads, nemesis) plus bot memory of you, and fixes from the Social Expansion audit.
- Every part is off by default and has its own switch in the launcher's Social Expansion tab.
- Automated tests pass.
- **Partly checked in game** (2026-10-17, builds 0.36-chris.3 to chris.8). Seen working: grats,
  server firsts, bots remembering you, the bot schedule, nemesis records, the Camelot Herald, a
  bot asking you for a rez by name, and a bot rezzing you. The checks found and fixed four bugs,
  merged in pull request #6; the one in shared AI code is that dead gamebots no longer jump to
  their spawn point. Not seen yet: frontier alarms, nemesis chat lines, "brb" in chat, linkdeads,
  and you rezzing a bot. Details are in LIVING-SERVER.md, "In-game check".
- **Branches (2026-10-17):** `feature/living-server` holds all the Social Expansion and Living
  Server code; release builds `0.36-chris.4` to `chris.8` were cut from it. `main` has only
  README, changelog and new-client updates, plus the same stuck-bot server fix that our branch
  already has from 0.36. It doesn't have this code yet.
- **Stages 4, 5 and 5b, first in-game pass (2026-10-17, chris.8):**
  - **XP by level range:** passes for players. Measured 3.0×, 5.0× and 12.0× in PvE zones, and
    the RvR rate in frontier zones. Bot rates weren't measured.
  - **Bot guilds:** items 1–5 work; merit wasn't seen yet. **Bug:** the realm's starting guild
    (Clan Cotswold) blocks recruiting, so "lf guild" gets no answer until you `/gc quit`. Keep
    claims, alliances and `/ginvite` on bots weren't checked. With 8 bots, Midgard and
    Hibernia formed no guild.
  - **Personalities and voices:** `/personality` works; all six types are on the roster. A
    debate started 5½ minutes in but was cut short after 24 s. Lines fit with no template
    leaks. Towns and long-term repetition weren't measured.
  - Details are in each feature's doc.
- **0.36-chris.9 (2026-10-17):**
  - The starting-guild fix and the debate wait were both checked in game, on 300 bots per realm
    (150 at level 1, 150 at level 50).
  - "lf guild" from Clan Cotswold got an invite, and accepting moved the character into the bot
    guild.
  - 5 guilds formed per realm, and 3 alliances.
  - A 5-speaker debate played to the end. The busy-speaker wait itself wasn't triggered.
  - Load: the launcher's bot AI delay was 0.8 ms with 549 bots online, 1.3 ms with 781, and
    1.2 ms with 889 (4 ms budget). The log showed no lag warnings and no errors.
- **Play session with chris.9, then 0.36-chris.10 (2026-10-17):**
  - It ran 80 minutes with every switch on. Results are in LIVING-SERVER.md, "Third check".
  - Seen: two debates finished, each after a busy-speaker wait; 9 frontier alarms; 52 "brb" breaks.
    No errors.
  - Fixed in chris.10 (pull request #8): tells, `/invite` and `/target` by name now reach bots,
    and the new client's target buttons and server target changes work. These were checked in
    game, as was a fix to the stick and follow toggle. A misplaced gossip line is fixed too, but
    not yet seen in game.
  - Found, not fixed (stock code): a low-level group can die for 15 minutes on its way to a
    meetup. "lfg" answers promise invites that bots never send.
- **Before the stage 7 merge into `main`:** decide whether the unchecked parts (keep claims, bot
  XP rates, linkdeads, nemesis chat lines, you rezzing a bot) must be seen first or can ship
  marked as unchecked.
- Docs: [LIVING-SERVER.md](LIVING-SERVER.md). Planning record:
  [LIVING-SERVER-BACKLOG.md](LIVING-SERVER-BACKLOG.md).

## 3. Decisions from Chris (2026-10-12)

1. **Stage 1:** go. Done.
2. **Stale branches:** delete. Claude's token can't delete branches (HTTP 403), so Chris deletes
   `living-world/roadmap` and `ci/github-actions` on GitHub.
3. **Release visibility:** public, at stage 7, after the tests pass.
4. **Scope:** hold the release for personalities, voices and debates ("Social Expansion").
