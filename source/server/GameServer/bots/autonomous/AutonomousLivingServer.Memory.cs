using System;
using System.Collections.Generic;
using System.Linq;

namespace DOL.GS;

/// <summary>
/// Bot memory of you (Living Server). An autonomous gamebot of your realm remembers grouping with
/// you, being rezzed by you and being insulted by you. It greets you when you pass, thanks you for
/// an old rez, answers you by name, sometimes mentions you in /faction, and stays cool after abuse.
/// Memory is chat only: it never changes who groups with whom.
/// </summary>
public static partial class AutonomousLivingServer
{
    public const long GroupedNoteIntervalMs = 30 * 60_000;
    public const long GreetPairCooldownMs = 45 * 60_000;
    public const long GreetPlayerCooldownMs = 3 * 60_000;
    public const long GossipRealmCooldownMinMs = 30 * 60_000;
    public const int GreetRange = 700;

    private static readonly Dictionary<(long BotId, string Player), long> LastGroupedNote = new();
    private static readonly Dictionary<(long BotId, string Player), long> LastGreeted = new();
    private static readonly Dictionary<string, long> LastGreetOfPlayer = new(StringComparer.OrdinalIgnoreCase);
    private static readonly Dictionary<eRealm, long> NextGossip = new();
    private static long _nextMemoryScan;

    /// <summary>friendly, neutral or cool: the mood tags of memory.lines.</summary>
    public static string MoodOf(int grouped, int rezzed, int abused)
    {
        int good = grouped + rezzed * 2;
        if (abused > 0 && abused * 2 >= good)
            return "cool";
        return good > 0 ? "friendly" : "neutral";
    }

    public static string MoodOf(OfflineBotMemoryRecord row) => MoodOf(row.Grouped, row.Rezzed, row.Abused);

    /// <summary>Notes an event with a player (topic rez, group or abuse).</summary>
    public static void Remember(GameBot bot, GamePlayer player, string topic)
    {
        if (!MemoryOn || !IsSpeaker(bot) || player == null || player.Realm != bot.Realm)
            return;
        string place = PlaceOf(bot);
        string now = DateTime.UtcNow.ToString("O");
        Memories.Change((bot.DatabaseID, player.Name), () => new OfflineBotMemoryRecord
        {
            BotId = bot.DatabaseID, PlayerName = player.Name, FirstMetUtc = now,
        }, row =>
        {
            row.PlayerClass = ClassOf(player);
            row.PlayerRealm = (int)player.Realm;
            row.LastSeenUtc = now;
            switch (topic)
            {
                case "rez": row.Rezzed++; break;
                case "group": row.Grouped++; break;
                case "abuse": row.Abused++; break;
            }
            if (topic != "abuse")
            {
                row.LastTopic = topic;
                if (!string.IsNullOrEmpty(place))
                    row.LastPlace = place;
            }
        });
    }

    /// <summary>A player insulted bots in chat; those who heard remember it.</summary>
    public static void RecordAbuse(IEnumerable<GameBot> heard, GamePlayer player)
    {
        if (!MemoryOn || heard == null)
            return;
        foreach (GameBot bot in heard.Take(3))
            Remember(bot, player, "abuse");
    }

    public static bool TryRecall(GameBot bot, GamePlayer player, out OfflineBotMemoryRecord row)
    {
        row = null;
        return MemoryOn && bot != null && player != null && Memories.TryGet((bot.DatabaseID, player.Name), out row);
    }

    private static Dictionary<string, string> MemorySlots(OfflineBotMemoryRecord row, GamePlayer player) => new(StringComparer.Ordinal)
    {
        ["player"] = player.Name,
        ["player_class"] = string.IsNullOrEmpty(row.PlayerClass) ? null : row.PlayerClass.ToLowerInvariant(),
        ["place"] = string.IsNullOrEmpty(row.LastPlace) ? null : row.LastPlace,
    };

    /// <summary>
    /// A reply to a player's chat by a bot that knows them: by name, or a cool brush-off after abuse.
    /// False when the bot doesn't know the player or no line fits (the caller keeps its old reply).
    /// </summary>
    public static bool TryKnownReply(GameBot bot, GamePlayer player, string intent, out string text)
    {
        text = null;
        if (!TryRecall(bot, player, out OfflineBotMemoryRecord row))
            return false;
        Dictionary<string, string> slots = MemorySlots(row, player);
        string mood = MoodOf(row);
        if (mood == "cool")
            return AutonomousBotVoices.TryEventLine(bot, "grudge", out text, slots: slots, flags: ["knows_player"], mood: "cool");
        // Only the lines written for a known player (topic "player"): the general replies don't use the name.
        return AutonomousBotVoices.TryEventLine(bot, "reply", out text, "player", slots, ["knows_player"], intent: intent);
    }

    /// <summary>Once a second on the game loop: grouping notes, greetings, gossip (each on its own timer).</summary>
    private static void MemoryPulse(long now)
    {
        if (now < _nextMemoryScan)
            return;
        _nextMemoryScan = now + 5_000;
        foreach (GamePlayer player in ClientService.Instance.GetPlayers())
        {
            if (player?.Client == null || player.ObjectState != GameObject.eObjectState.Active || player.CurrentRegion == null)
                continue;
            NoteGroupmates(player, now);
            if (player.IsAlive && !player.InCombat)
                TryGreet(player, now);
        }
        TryGossip(now);
    }

    private static void NoteGroupmates(GamePlayer player, long now)
    {
        if (player.Group == null)
            return;
        foreach (GameBot bot in player.Group.GetMembersInTheGroup().OfType<GameBot>())
        {
            if (!IsSpeaker(bot) || bot.Realm != player.Realm)
                continue;
            var key = (bot.DatabaseID, player.Name);
            lock (LastGroupedNote)
            {
                if (LastGroupedNote.TryGetValue(key, out long last) && now - last < GroupedNoteIntervalMs)
                    continue;
                LastGroupedNote[key] = now;
            }
            Remember(bot, player, "group");
        }
    }

    private static void TryGreet(GamePlayer player, long now)
    {
        lock (LastGreeted)
            if (LastGreetOfPlayer.TryGetValue(player.Name, out long last) && now - last < GreetPlayerCooldownMs)
                return;
        foreach (GameBot bot in player.GetNPCsInRadius(GreetRange).OfType<GameBot>())
        {
            if (!CanTalk(bot) || bot.Realm != player.Realm || bot.Group != null && bot.Group == player.Group ||
                !Memories.TryGet((bot.DatabaseID, player.Name), out OfflineBotMemoryRecord row) ||
                row.Grouped + row.Rezzed + row.Abused == 0)
                continue;
            var key = (bot.DatabaseID, player.Name);
            lock (LastGreeted)
            {
                if (LastGreeted.TryGetValue(key, out long greeted) && now - greeted < GreetPairCooldownMs)
                    continue;
                LastGreeted[key] = now;
                LastGreetOfPlayer[player.Name] = now;
            }
            Dictionary<string, string> slots = MemorySlots(row, player);
            string mood = MoodOf(row);
            bool thanks = mood == "friendly" && row.LastTopic is "rez" or "group" && Random.Shared.NextDouble() < 0.3;
            Later(bot, 1_000 + Random.Shared.Next(2_500), () => CanTalk(bot) && bot.IsWithinRadius(player, WorldMgr.SAY_DISTANCE), () =>
            {
                string line = null;
                if (thanks)
                    AutonomousBotVoices.TryEventLine(bot, "thanks", out line, row.LastTopic, slots, ["knows_player", "player_nearby"]);
                if (line == null)
                    AutonomousBotVoices.TryEventLine(bot, "greet", out line, slots: slots, flags: ["knows_player", "player_nearby"], mood: mood);
                if (line != null)
                    Speak(bot, Channel.Say, line);
            });
            return;
        }
    }

    /// <summary>Now and then a bot that likes you mentions you in /faction (never one standing next to you).</summary>
    private static void TryGossip(long now)
    {
        foreach (eRealm realm in new[] { eRealm.Albion, eRealm.Midgard, eRealm.Hibernia })
        {
            List<GamePlayer> players = ClientService.Instance.GetPlayersOfRealm(realm);
            if (players.Count == 0)
                continue;
            lock (NextGossip)
            {
                if (!NextGossip.TryGetValue(realm, out long next))
                {
                    NextGossip[realm] = now + GossipRealmCooldownMinMs / 2 + Random.Shared.Next(15 * 60_000);
                    continue;
                }
                if (now < next)
                    continue;
                NextGossip[realm] = now + GossipRealmCooldownMinMs + Random.Shared.Next(30 * 60_000);
            }
            if (AutonomousBotDebates.IsRunning(realm))
                continue;
            GamePlayer subject = players[Random.Shared.Next(players.Count)];
            OfflineBotMemoryRecord[] friends = Memories.Where(row => string.Equals(row.PlayerName, subject.Name, StringComparison.OrdinalIgnoreCase) &&
                                                                     MoodOf(row) == "friendly" && row.Grouped + row.Rezzed >= 2);
            foreach (OfflineBotMemoryRecord row in friends.OrderBy(_ => Random.Shared.Next()))
            {
                if (!AutonomousBotRegistry.TryGet(row.BotId, out GameBot bot) || !CanTalk(bot) ||
                    bot.CurrentRegion == subject.CurrentRegion && bot.IsWithinRadius(subject, WorldMgr.SAY_DISTANCE * 2))
                    continue;
                if (AutonomousBotVoices.TryEventLine(bot, "gossip", out string line, slots: MemorySlots(row, subject),
                        flags: AutonomousBotGuildSocial.CountsAsGuildless(subject.Guild) ? ["knows_player", "player_guildless"] : ["knows_player"],
                        mood: "friendly"))
                    Speak(bot, Channel.Faction, line);
                break;
            }
        }
    }
}
