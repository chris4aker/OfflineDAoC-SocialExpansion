using System;
using System.Linq;
using System.Reflection;
using DOL.Events;
using DOL.GS.ServerProperties;
using DOL.Logging;

namespace DOL.GS;

/// <summary>
/// Names this server build in the log at startup (docs/RELEASE-PLAN.md): the fork build name, the
/// git commit it was built from, and which fork features are switched on. One line, so a log shows
/// at a glance what was running.
/// </summary>
public static class ForkBuildInfo
{
    /// <summary>The fork's build name; bump it with each fork release.</summary>
    public const string BuildName = "0.36-chris.10";

    private static readonly Logger Log = LoggerManager.Create(MethodBase.GetCurrentMethod().DeclaringType);

    /// <summary>The git commit, from the informational version CI stamps (<c>-p:SourceRevisionId=sha</c>); "local" otherwise.</summary>
    public static string Commit
    {
        get
        {
            string version = typeof(ForkBuildInfo).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion;
            return CommitFrom(version);
        }
    }

    public static string CommitFrom(string informationalVersion)
    {
        int plus = informationalVersion?.IndexOf('+') ?? -1;
        if (plus < 0 || plus == informationalVersion.Length - 1)
            return "local";
        string sha = informationalVersion[(plus + 1)..];
        return sha.Length > 12 ? sha[..12] : sha;
    }

    /// <summary>The startup line, from the current settings.</summary>
    public static string Describe()
    {
        string On(bool value) => value ? "on" : "off";
        string guildParts = string.Join(",", new[]
        {
            ("social", Properties.BOT_GUILD_SOCIAL), ("recruit", Properties.BOT_GUILD_RECRUIT_PLAYER),
            ("claims", Properties.BOT_GUILD_CLAIMS_KEEPS), ("economy", Properties.BOT_GUILD_ECONOMY),
            ("alliances", Properties.BOT_GUILD_ALLIANCES),
        }.Where(part => part.Item2).Select(part => part.Item1));
        string livingParts = string.Join(",", new[]
        {
            ("memory", Properties.BOT_LIVING_MEMORY), ("grats", Properties.BOT_LIVING_GRATS), ("firsts", Properties.BOT_LIVING_FIRSTS),
            ("death", Properties.BOT_LIVING_DEATH), ("alarms", Properties.BOT_LIVING_ALARMS), ("nemesis", Properties.BOT_LIVING_NEMESIS),
            ("breaks", Properties.BOT_LIVING_BREAKS),
        }.Where(part => part.Item2).Select(part => part.Item1));
        string Range(string spec) => string.IsNullOrWhiteSpace(spec) ? "off" : $"\"{spec.Trim()}\"";
        return $"FORK_BUILD name={BuildName} commit={Commit} " +
               $"bot_guilds={On(Properties.BOT_GUILDS_ENABLED)}" +
               (Properties.BOT_GUILDS_ENABLED ? $" bot_guild_parts={(guildParts.Length == 0 ? "none" : guildParts)}" : string.Empty) +
               $" xp_rate_by_level={Range(Properties.XP_RATE_BY_LEVEL)} bot_xp_rate_by_level={Range(Properties.BOT_XP_RATE_BY_LEVEL)}" +
               $" bot_personalities={On(Properties.BOT_PERSONALITIES_ENABLED)} bot_voices={On(Properties.BOT_VOICES_ENABLED)}" +
               (Properties.BOT_VOICES_ENABLED ? $" bot_debates={On(Properties.BOT_VOICES_DEBATES)}" : string.Empty) +
               $" living={(livingParts.Length == 0 ? "off" : livingParts)} bot_schedule={AutonomousBotSchedule.CurrentMode.ToString().ToLowerInvariant()}";
    }

    [GameServerStartedEvent]
    public static void OnServerStarted(DOLEvent e, object sender, EventArgs args)
    {
        try
        {
            string line = Describe();
            // Warn level so it shows even when the log is set to warnings only.
            if (Log.IsWarnEnabled)
                Log.Warn(line);
        }
        catch (Exception exception)
        {
            Log.Error("FORK_BUILD: could not describe this build", exception);
        }
    }
}
