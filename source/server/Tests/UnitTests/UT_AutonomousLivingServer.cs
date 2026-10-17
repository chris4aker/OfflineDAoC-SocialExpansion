using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using DOL.GS.ServerProperties;
using NUnit.Framework;
using Schedule = DOL.GS.AutonomousBotSchedule;
using Living = DOL.GS.AutonomousLivingServer;
using VC = DOL.GS.AutonomousBotVoiceCorpus;

namespace DOL.GS.Tests
{
    /// <summary>The Living Server's rules that need no running world (docs/LIVING-SERVER.md).</summary>
    [TestFixture]
    public class UT_AutonomousLivingServer
    {
        #region Settings

        [Test]
        public void EveryPartIsOffByDefault()
        {
            var fields = typeof(Properties).GetFields();
            foreach (string name in new[] { "BOT_LIVING_MEMORY", "BOT_LIVING_GRATS", "BOT_LIVING_FIRSTS", "BOT_LIVING_DEATH",
                         "BOT_LIVING_ALARMS", "BOT_LIVING_NEMESIS", "BOT_LIVING_BREAKS" })
            {
                var field = fields.Single(f => f.Name == name);
                var attribute = (ServerPropertyAttribute)Attribute.GetCustomAttribute(field, typeof(ServerPropertyAttribute));
                Assert.That(attribute.DefaultValue, Is.EqualTo(false), name);
                Assert.That(attribute.Category, Is.EqualTo("bots"), name);
            }
            var mode = (ServerPropertyAttribute)Attribute.GetCustomAttribute(fields.Single(f => f.Name == "BOT_SCHEDULE_MODE"), typeof(ServerPropertyAttribute));
            Assert.That(mode.DefaultValue, Is.EqualTo("off"));
            Assert.That(Schedule.Parse((string)mode.DefaultValue), Is.EqualTo(Schedule.Mode.Off));
        }

        [TestCase("off", Schedule.Mode.Off)]
        [TestCase("", Schedule.Mode.Off)]
        [TestCase(null, Schedule.Mode.Off)]
        [TestCase("nonsense", Schedule.Mode.Off)]
        [TestCase("realclock", Schedule.Mode.Off)]
        [TestCase("session", Schedule.Mode.Session)]
        [TestCase(" Session ", Schedule.Mode.Session)]
        [TestCase("clock", Schedule.Mode.Clock)]
        [TestCase("CLOCK", Schedule.Mode.Clock)]
        public void ScheduleModesParseLikeTheLauncherWritesThem(string text, Schedule.Mode expected) =>
            Assert.That(Schedule.Parse(text), Is.EqualTo(expected));

        [Test]
        public void WithTheScheduleOffEveryBotWantsToBeOnline()
        {
            string mode = Properties.BOT_SCHEDULE_MODE;
            bool breaks = Properties.BOT_LIVING_BREAKS;
            try
            {
                Properties.BOT_SCHEDULE_MODE = "off";
                Properties.BOT_LIVING_BREAKS = false;
                Assert.That(Schedule.Active, Is.False);
                for (long id = 1; id < 200; id++)
                    Assert.That(Schedule.WantsOnline(new OfflineWorldBotRecord { BotId = id }, DateTime.UtcNow), Is.True);
            }
            finally
            {
                Properties.BOT_SCHEDULE_MODE = mode;
                Properties.BOT_LIVING_BREAKS = breaks;
            }
        }

        #endregion

        #region Schedule math

        [Test]
        public void MixIsStableAndSpreadsIds()
        {
            Assert.That(Schedule.Mix(42, 1), Is.EqualTo(Schedule.Mix(42, 1)));
            Assert.That(Schedule.Mix(42, 1), Is.Not.EqualTo(Schedule.Mix(43, 1)));
            Assert.That(Schedule.Mix(42, 1), Is.Not.EqualTo(Schedule.Mix(42, 2)));
            double mean = Enumerable.Range(1, 10_000).Average(id => Schedule.Unit(id, 7));
            Assert.That(mean, Is.InRange(0.48, 0.52));
        }

        [Test]
        public void SessionsLastOneToFourHoursWithShortTimesAway()
        {
            for (long id = 1; id <= 2_000; id++)
            {
                (int online, int away) = Schedule.SessionLengths(id, BotPersonalityType.Leveler);
                Assert.That(online, Is.InRange(60, 240));
                Assert.That(away, Is.InRange(20, 120));
            }
            (int noLiferOnline, int noLiferAway) = Schedule.SessionLengths(5, BotPersonalityType.NoLifer);
            (int levelerOnline, int levelerAway) = Schedule.SessionLengths(5, BotPersonalityType.Leveler);
            Assert.That(noLiferOnline, Is.GreaterThan(levelerOnline));
            Assert.That(noLiferAway, Is.LessThan(levelerAway));
        }

        [Test]
        public void SessionModeKeepsMostBotsOnAndChangesSlowly()
        {
            var at = TimeSpan.FromMinutes(300);
            double share = Enumerable.Range(1, 4_000).Count(id => Schedule.SessionOnline(id, BotPersonalityType.Leveler, at)) / 4000.0;
            Assert.That(share, Is.InRange(0.55, 0.80), "most of the roster is online at any time");
            for (long id = 1; id <= 300; id++)
            {
                int changes = 0;
                bool last = Schedule.SessionOnline(id, BotPersonalityType.Leveler, TimeSpan.Zero);
                for (int minute = 1; minute <= 8 * 60; minute++)
                {
                    bool now = Schedule.SessionOnline(id, BotPersonalityType.Leveler, TimeSpan.FromMinutes(minute));
                    if (now != last) changes++;
                    last = now;
                }
                Assert.That(changes, Is.LessThanOrEqualTo(12), $"bot {id} does not flicker");
            }
        }

        [Test]
        public void ClockModeIsBusyInTheEveningAndQuietOvernight()
        {
            var tuesdayEvening = new DateTime(2026, 10, 13, 21, 0, 0, DateTimeKind.Local);
            var tuesdayDawn = new DateTime(2026, 10, 13, 5, 0, 0, DateTimeKind.Local);
            var saturdayAfternoon = new DateTime(2026, 10, 17, 15, 0, 0, DateTimeKind.Local);
            Assert.That(Schedule.ClockShare(tuesdayEvening), Is.GreaterThanOrEqualTo(0.9));
            Assert.That(Schedule.ClockShare(tuesdayDawn), Is.LessThanOrEqualTo(0.25));
            Assert.That(Schedule.ClockShare(saturdayAfternoon), Is.GreaterThan(Schedule.ClockShare(tuesdayDawn.AddHours(10))));
            double Share(DateTime local) => Enumerable.Range(1, 5_000).Count(id => Schedule.ClockOnline(id, BotPersonalityType.Leveler, local)) / 5000.0;
            Assert.That(Share(tuesdayEvening), Is.EqualTo(Schedule.ClockShare(tuesdayEvening)).Within(0.04));
            Assert.That(Share(tuesdayDawn), Is.EqualTo(Schedule.ClockShare(tuesdayDawn)).Within(0.04));
            double noLifers = Enumerable.Range(1, 5_000).Count(id => Schedule.ClockOnline(id, BotPersonalityType.NoLifer, tuesdayDawn)) / 5000.0;
            Assert.That(noLifers, Is.GreaterThan(Share(tuesdayDawn)), "no-lifers stay up late");
        }

        [Test]
        public void ClockModeKeepsTheSameBotsOnAsTheEveningFillsUp()
        {
            var dawn = new DateTime(2026, 10, 14, 5, 0, 0, DateTimeKind.Local);
            var evening = dawn.AddHours(16);
            for (long id = 1; id <= 3_000; id++)
                if (Schedule.ClockOnline(id, BotPersonalityType.Leveler, dawn))
                    Assert.That(Schedule.ClockOnline(id, BotPersonalityType.Leveler, evening), Is.True,
                        "a bot up at dawn is still up when the evening crowd arrives");
        }

        #endregion

        #region Memory, alarms, names

        [TestCase(0, 0, 0, "neutral")]
        [TestCase(1, 0, 0, "friendly")]
        [TestCase(0, 1, 0, "friendly")]
        [TestCase(1, 0, 1, "cool")]
        [TestCase(3, 1, 1, "friendly")]
        [TestCase(0, 0, 2, "cool")]
        public void MoodFollowsWhatTheBotRemembers(int grouped, int rezzed, int abused, string mood) =>
            Assert.That(Living.MoodOf(grouped, rezzed, abused), Is.EqualTo(mood));

        [TestCase(3, "3")]
        [TestCase(8, "8")]
        [TestCase(9, "9")]
        [TestCase(10, "10")]
        [TestCase(14, "10")]
        [TestCase(23, "20")]
        public void AlarmsGiveARoughHeadCount(int count, string size) => Assert.That(Living.AlarmSize(count), Is.EqualTo(size));

        [Test]
        public void RacesAndRealmsAreNamedAsPlayersSaidThem()
        {
            Assert.That(Living.RaceWord((int)eRace.Troll), Is.EqualTo("troll"));
            Assert.That(Living.RaceWord((int)eRace.HalfOgre), Is.EqualTo("half ogre"));
            Assert.That(Living.RaceWord(20), Is.EqualTo("minotaur"));
            Assert.That(Living.RaceWord(0), Is.Empty);
            Assert.That(Living.RealmPlural(eRealm.Midgard), Is.EqualTo("mids"));
            Assert.That(Living.RealmPlural(eRealm.Albion), Is.EqualTo("albs"));
            Assert.That(Living.RealmPlural(eRealm.Hibernia), Is.EqualTo("hibs"));
        }

        [Test]
        public void TablesClaimAFirstOnceAndChangeRowsInPlace()
        {
            var firsts = new LivingServerTable<string, OfflineServerFirstRecord>("test", row => row.Title, StringComparer.OrdinalIgnoreCase);
            Assert.That(firsts.TryAdd("First to reach level 50", new OfflineServerFirstRecord { Title = "First to reach level 50", Name = "A" }), Is.True);
            Assert.That(firsts.TryAdd("first to reach LEVEL 50", new OfflineServerFirstRecord { Title = "x", Name = "B" }), Is.False);
            Assert.That(firsts.TryGet("First to reach level 50", out var row) && row.Name == "A", Is.True);

            var nemesis = new LivingServerTable<(long, string), OfflineBotNemesisRecord>("test", r => (r.BotId, r.KillerName));
            for (int i = 0; i < 3; i++)
                nemesis.Change((7, "Brannoc"), () => new OfflineBotNemesisRecord { BotId = 7, KillerName = "Brannoc" }, r => r.Kills++);
            Assert.That(nemesis.Count, Is.EqualTo(1));
            Assert.That(nemesis.TryGet((7, "Brannoc"), out var killer) && killer.Kills == 3, Is.True);
        }

        [Test]
        public void TablesWriteChangesDeletesAndReloadThemFromSqlite()
        {
            // Review 2026-10-16: rows were only ever inserted, never updated, because changed rows weren't dirty.
            string folder = Path.Combine(Path.GetTempPath(), "living-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(folder);
            try
            {
                var database = DOL.Database.ObjectDatabase.GetObjectDatabase(DOL.Database.Connection.EConnectionType.DATABASE_SQLITE,
                    $"Data Source={Path.Combine(folder, "living.db")};Pooling=False");
                database.RegisterDataObject(typeof(OfflineBotNemesisRecord));
                LivingServerTable<(long, string), OfflineBotNemesisRecord> Table() =>
                    new("test", r => (r.BotId, r.KillerName), null, () => database);
                var table = Table();
                OfflineBotNemesisRecord Create(long bot, string killer) => new() { BotId = bot, KillerName = killer };
                table.Change((1, "Troll"), () => Create(1, "Troll"), r => r.Kills++);
                table.Change((1, "Kobold"), () => Create(1, "Kobold"), r => r.Kills++);
                table.Flush();
                table.Change((1, "Troll"), () => Create(1, "Troll"), r => r.Kills++);
                table.Change((1, "Troll"), () => Create(1, "Troll"), r => r.Revenges++);
                table.Flush();
                Assert.That(table.RemoveWhere(r => r.KillerName == "Kobold"), Is.EqualTo(1));
                table.Flush(wait: true);

                var reloaded = Table();
                reloaded.Load(database.SelectAllObjects<OfflineBotNemesisRecord>());
                Assert.That(reloaded.Count, Is.EqualTo(1), "the removed row is deleted");
                Assert.That(reloaded.TryGet((1, "Troll"), out var troll), Is.True);
                Assert.That((troll.Kills, troll.Revenges), Is.EqualTo((2, 1)), "changes after the first insert are saved");
            }
            finally
            {
                System.Data.SQLite.SQLiteConnection.ClearAllPools();
                try { Directory.Delete(folder, true); } catch (IOException) { }
            }
        }

        #endregion

        #region Lines

        private static VC _corpus;

        private static VC Corpus => _corpus ??= AutonomousBotVoices.Corpus;

        private static Dictionary<string, string> Slots(params (string Key, string Value)[] extra)
        {
            var slots = new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["me"] = "Aldwin", ["class"] = "cleric", ["level"] = "30", ["realm"] = "Albion", ["zone"] = "Pennine Mountains",
                ["monster"] = "bwca", ["item"] = "a sword", ["count"] = "3", ["q"] = "", ["keep"] = "Caer Benowyc",
                ["frontier"] = "Pennine Mountains", ["enemy"] = "Midgard", ["capital"] = "Camelot", ["dungeon"] = "Tomb of Mithra",
                ["camp"] = "Tomb of Mithra",
            };
            foreach (var (key, value) in extra)
                slots[key] = value;
            return slots;
        }

        private static VC.Speaker Speaker(BotPersonalityType type, params string[] flags) =>
            new(11, "Aldwin", eRealm.Albion, "Cleric", 30, type, new HashSet<string>(flags, StringComparer.Ordinal));

        [Test]
        public void NemesisLinesNameARaceAndClassNeverAName()
        {
            var random = new Random(4);
            var slots = Slots(("killer", "troll"), ("killer_class", "berserker"), ("place", "Caer Benowyc"));
            var seen = new HashSet<string>();
            for (int i = 0; i < 200; i++)
                foreach (string kind in new[] { "nemesis", "revenge" })
                    if (Corpus.TryPick(kind, Speaker((BotPersonalityType)(i % 6)), slots, null, DateTime.UtcNow, random, out string text, out _))
                        seen.Add(text.ToLowerInvariant());
            Assert.That(seen, Is.Not.Empty);
            Assert.That(seen.Any(text => text.Contains("berserker")), Is.True);
            Assert.That(seen.All(text => !text.Contains('{')), Is.True, "every slot was filled");
        }

        [Test]
        public void AlarmLinesNeedTheFrontierAndFillEverySlot()
        {
            var random = new Random(8);
            var slots = Slots(("size", "8"), ("enemy", "mids"), ("place", "Caer Benowyc"), ("classes", "healer, warrior"));
            Assert.That(Corpus.TryPick("alarm", Speaker(BotPersonalityType.Leveler), slots, null, DateTime.UtcNow, random, out _, out _),
                Is.False, "no alarm outside the frontier");
            for (int i = 0; i < 30; i++)
            {
                Assert.That(Corpus.TryPick("alarm", Speaker(BotPersonalityType.Daredevil, "in_rvr"), slots, null, DateTime.UtcNow, random,
                    out string text, out _), Is.True);
                Assert.That(text, Does.Not.Contain("{"));
            }
        }

        [Test]
        public void GreetingsFollowTheRememberedMood()
        {
            var random = new Random(2);
            var slots = Slots(("player", "Chrisplays"), ("player_class", "cleric"), ("place", "Tomb of Mithra"));
            var byId = Corpus.Lines.ToDictionary(line => line.Id);
            foreach (string mood in new[] { "friendly", "neutral", "cool" })
                for (int i = 0; i < 20; i++)
                {
                    Assert.That(Corpus.TryPick("greet", Speaker(BotPersonalityType.Socialite, "knows_player", "player_nearby"), slots, null,
                        DateTime.UtcNow, random, out _, out string id, mood: mood), Is.True, mood);
                    Assert.That(byId[id].Mood, Is.EqualTo(mood));
                }
        }

        [Test]
        public void GossipAboutGettingAPlayerIntoAGuildOnlyWhenTheyHaveNone()
        {
            // In-game check 2026-10-17: "we should get Claudecheck into a guild" while Claudecheck was in a bot guild.
            var random = new Random(4);
            var slots = Slots(("player", "Claudecheck"), ("player_class", "cleric"), ("place", "Campacorentin Forest"));
            var picked = new Dictionary<bool, HashSet<string>> { [false] = new(), [true] = new() };
            foreach (bool guildless in new[] { false, true })
                for (int i = 0; i < 400; i++)
                    if (Corpus.TryPick("gossip", guildless ? Speaker(BotPersonalityType.Socialite, "knows_player", "player_guildless")
                                                           : Speaker(BotPersonalityType.Socialite, "knows_player"),
                            slots, null, DateTime.UtcNow, random, out string text, out _, mood: "friendly"))
                        picked[guildless].Add(text);
            Assert.That(picked[false].Where(text => text.Contains("into a guild")), Is.Empty);
            Assert.That(picked[true].Where(text => text.Contains("into a guild")), Is.Not.Empty);
        }

        [Test]
        public void FirstsAreSeededOnceSoBotsMadeAtFiftyLaterDontTakeThem()
        {
            // In-game check 2026-10-17: every start re-seeded, so "+ Lv.50" bots took every level-50 title.
            var firsts = new LivingServerTable<string, OfflineServerFirstRecord>("test", row => row.Title, StringComparer.OrdinalIgnoreCase);
            int seeded = 0;
            AutonomousLivingServer.SeedFirstsOnce(firsts, false, () => seeded++);
            Assert.That((seeded, firsts.Count), Is.EqualTo((0, 0)), "switched off: nothing seeded, nothing written");
            AutonomousLivingServer.SeedFirstsOnce(firsts, true, () => seeded++);
            Assert.That(seeded, Is.EqualTo(1), "the first start with the switch on seeds");
            Assert.That(firsts.TryGet(AutonomousLivingServer.RecordsBeganTitle, out var marker) && marker.Name == "", Is.True,
                "the marker has no name, so the Herald never lists it");
            AutonomousLivingServer.SeedFirstsOnce(firsts, true, () => seeded++);
            AutonomousLivingServer.SeedFirstsOnce(firsts, true, () => seeded++);
            Assert.That(seeded, Is.EqualTo(1), "later starts don't seed again");
            AutonomousLivingServer.SeedFirstsOnce(firsts, false, () => seeded++);
            Assert.That(firsts.TryGet(AutonomousLivingServer.RecordsBeganTitle, out _), Is.False, "switching off forgets the marker");
            AutonomousLivingServer.SeedFirstsOnce(firsts, true, () => seeded++);
            Assert.That(seeded, Is.EqualTo(2), "switching on again seeds who got there meanwhile");
        }

        [Test]
        public void ARememberedPlayerIsAnsweredByNameForEveryOrdinaryIntent()
        {
            // In-game check 2026-10-17: known replies were drawn from the general pool too, so few used the name.
            var random = new Random(6);
            var slots = Slots(("player", "Chrisplays"), ("player_class", "cleric"), ("place", "Tomb of Mithra"));
            foreach (string intent in new[] { "greeting", "grouping", "farewell", "grinding", "travel", "help", "banter", "rvr",
                         "dungeon", "trading", "unknown" })
                for (int i = 0; i < 12; i++)
                {
                    Assert.That(Corpus.TryPick("reply", Speaker((BotPersonalityType)(i % 6), "knows_player"), slots, null, DateTime.UtcNow,
                        random, out string text, out _, intent, "player"), Is.True, intent);
                    Assert.That(text, Does.Contain("Chrisplays").IgnoreCase, intent);
                }
            Assert.That(Corpus.Lines.Where(line => line.Kind == "reply" && line.Topic == "player").All(line => line.Text.Contains("{player}")),
                Is.True, "every known-player reply uses the name");
            Assert.That(Corpus.TryPick("reply", Speaker(BotPersonalityType.Leveler), slots, null, DateTime.UtcNow, random, out _, out _,
                "greeting", "player"), Is.False, "only for a bot that knows the player");
        }

        [Test]
        public void TheLivingServerDocumentListsEverySetting()
        {
            string dir = TestContext.CurrentContext.TestDirectory;
            while (dir != null && !File.Exists(Path.Combine(dir, "docs", "LIVING-SERVER.md")))
                dir = Path.GetDirectoryName(dir);
            if (dir == null)
                Assert.Ignore("docs/LIVING-SERVER.md not found beside the tests.");
            string doc = File.ReadAllText(Path.Combine(dir, "docs", "LIVING-SERVER.md"));
            foreach (string key in new[] { "bot_living_memory", "bot_living_grats", "bot_living_firsts", "bot_living_death",
                         "bot_living_alarms", "bot_living_nemesis", "bot_schedule_mode", "bot_living_breaks" })
                Assert.That(doc, Does.Contain(key));
        }

        #endregion
    }
}
