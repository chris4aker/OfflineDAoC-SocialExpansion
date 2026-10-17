namespace DOL.GS;

public static class BotGroupInvite
{
    /// <summary>/invite by name reaches an autonomous bot only nearby: it walks to you, it can't cross regions.</summary>
    public const int InviteByNameRange = 6_000;

    public static bool CloseEnoughToInviteByName(GamePlayer player, GameBot bot) =>
        player?.CurrentRegion != null && bot?.CurrentRegion == player.CurrentRegion && player.IsWithinRadius(bot, InviteByNameRange);

    public static bool TryInvite(GamePlayer player, GameBot bot)
    {
        if (player == null || bot == null || player.Realm != bot.Realm)
        {
            if (player != null)
                ChatUtil.SendSystemMessage(player, "Only a bot of your realm will accept the invitation.");
            return false;
        }

        if (player.Group != null && player.Group.Leader != player)
        {
            ChatUtil.SendSystemMessage(player, "You are not the leader of your group.");
            return false;
        }

        if (player.Group != null && player.Group.MemberCount >= ServerProperties.Properties.GROUP_MAX_MEMBER)
        {
            ChatUtil.SendSystemMessage(player, "The group is full.");
            return false;
        }

        if (bot.Group != null)
        {
            bool autonomousGroup = bot.PlayerGroupLeader == null;
            if (!autonomousGroup)
            {
                ChatUtil.SendSystemMessage(player, $"{bot.Name} is already following another player-led group.");
                return false;
            }

            bot.Group.RemoveMember(bot);
            ChatUtil.SendSystemMessage(player, $"{bot.Name} leaves the autonomous group to answer your invitation.");
        }

        if (player.Group == null)
        {
            var group = new Group(player);
            GroupMgr.AddGroup(group);
            group.AddMember(player);
        }

        if (!player.Group.AddMember(bot) || !bot.EnterPlayerLedGroup(player))
            return false;

        bot.PathTo(player, bot.MaxSpeed);
        ChatUtil.SendSystemMessage(player, $"{bot.Name} joins your group and starts moving to you.");
        return true;
    }
}
