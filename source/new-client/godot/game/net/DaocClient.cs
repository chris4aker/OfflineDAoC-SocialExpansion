// The game's link to the Offline DAoC server (Offline DAoC Rebuilt, owner 2026-10-11): the Godot game is a real DAoC
// client of the unchanged OpenDAoC server the launcher runs - it connects as the original client (game.dll 1.127) did.
// Formats follow the server's own code (external\old_project\development-source\server: GameClient.cs,
// PacketProcessor.cs, packets\Client\168, packets\Server\PacketLib1126/1127, CoreBase\Network\PacketOut.cs):
//   client -> server: [data length u16 BE][sequence u16][session u16][parameter u16][code u16 (low byte)] data [checksum]
//   server -> client: [data length u16 BE][code u8] data
// Strings are Windows-1252; no RC4 (the launcher's server has client encryption off unless the client sends a key).
// Received packets are read on a background thread and handed to the main thread (signals) in _Process.
using Godot;
using System;
using System.Collections.Concurrent;
using System.Net.Sockets;
using System.Text;
using System.Threading;

namespace MMOEngine;

public partial class DaocClient : Node
{
	public const int Port = 10300;
	public const byte ClientType = 0x06;          // ClientType & 0x0F: 6 = Labyrinth of the Minotaur client (every expansion on)
	public static readonly byte[] Version = { 1, 1, 27 };   // 1.127, as game.dll announced it
	static readonly Encoding Text1252 = CodePagesEncodingProvider.Instance.GetEncoding(1252);

	[Signal] public delegate void ConnectedEventHandler();
	[Signal] public delegate void DisconnectedEventHandler(string why);
	[Signal] public delegate void LoggedInEventHandler(string account, string serverName);
	[Signal] public delegate void LoginFailedEventHandler(int code);
	[Signal] public delegate void RealmEventHandler(int realm);
	[Signal] public delegate void CharactersEventHandler(int realm, Godot.Collections.Array characters);
	[Signal] public delegate void SessionEventHandler(int sessionId);
	[Signal] public delegate void PacketEventHandler(int code, byte[] data);   // everything not decoded here yet
	[Signal] public delegate void WorldEventHandler(string kind, Godot.Collections.Dictionary data);   // the world packets (ReadWorld)

	TcpClient _tcp;
	NetworkStream _stream;
	Thread _reader;
	readonly ConcurrentQueue<(int code, byte[] data)> _inbox = new();
	readonly object _sendLock = new();
	ushort _sequence;
	public int SessionId;
	public string Account = "";
	readonly ConcurrentQueue<int> _wantRealms = new();   // the realms asked for, in order (each overview answers one)
	int _lastRealm;

	static DaocClient()
	{
		Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
	}

	// ---------------------------------------------------------------- connecting

	// Connects and sends the handshake (the crypt key request announcing client 1.127).
	public bool Open(string host)
	{
		try
		{
			_tcp = new TcpClient { NoDelay = true };
			_tcp.Connect(host, Port);
			_stream = _tcp.GetStream();
		}
		catch (Exception e)
		{
			EmitSignal(SignalName.Disconnected, "could not connect to the server: " + e.Message);
			return false;
		}
		_reader = new Thread(ReadLoop) { IsBackground = true, Name = "DaocClient reader" };
		_reader.Start();
		// CryptKeyRequestHandler: client type, version (1, 1, 27), revision letter, build (u16)
		var w = new Writer();
		w.Byte(ClientType);
		w.Bytes(Version);
		w.Byte((byte)'a');
		w.Short(0);
		Send(0xF4, w);
		EmitSignal(SignalName.Connected);
		return true;
	}

	public void Close()
	{
		try { _tcp?.Close(); } catch (Exception) { }
		_tcp = null;
	}

	public bool IsOpen => _tcp != null && _tcp.Connected;

	// LoginRequestHandler (1.126+): username and password, each a little-endian u32 length and its bytes.
	public void Login(string account, string password)
	{
		Account = account;
		var w = new Writer();
		w.IntPascal(account);
		w.IntPascal(password);
		Send(0xA7, w);
	}

	// CharacterOverviewRequestHandler (1.124+): one byte - 0 asks which realm the account may use, 1-3 that realm's list.
	public void RequestCharacters(int realm)
	{
		if (realm != 0) _wantRealms.Enqueue(realm);
		var w = new Writer();
		w.Byte((byte)realm);
		Send(0xFC, w);
	}

	// DuplicateNameCheckRequestHandler (1.126+): the name in 24 bytes; the reply is DupNameCheck (0 free, 1 bad, 2 taken).
	public void CheckName(string name)
	{
		var w = new Writer();
		w.Fixed(name, 24);
		Send(0xCB, w);
	}

	// CharacterCreateRequestHandler.CreationCharacterData (1.126+ layout), operation 1 = create. The slot counts across
	// the realms (realm 2's first slot is 10). Face bytes are stored as given (CustomMode 1).
	public void CreateCharacter(Godot.Collections.Dictionary c)
	{
		int realm = (int)c["realm"];
		var w = new Writer();
		w.Byte((byte)((int)c["slot"] + (realm - 1) * 10));
		w.IntPascal((string)c["name"]);
		w.Bytes(new byte[] { 0x18, 0, 0, 0 });
		w.Byte(1);                                    // CustomMode: the face bytes below are the character's
		var face = (Godot.Collections.Array)c["face"];   // eye size, lip size, eye colour, hair colour, face, hair style, mood
		for (int i = 0; i < 6; i++) w.Byte((byte)(int)face[i]);
		w.Bytes(new byte[3]);
		w.Byte((byte)(int)face[6]);
		w.Bytes(new byte[9]);
		w.Byte(1);                                    // operation: create
		w.Byte(0);                                    // customize type
		w.Bytes(new byte[2]);
		w.Bytes(new byte[15]);                        // location, class and race names (the server skips them)
		w.Byte((byte)(int)c["class_id"]);
		w.Byte((byte)realm);
		w.Byte((byte)(((int)c["race"] & 0x1F) | ((int)c["gender"] << 7)));
		w.ShortLE((ushort)(int)c["model"]);
		var stats = (Godot.Collections.Array)c["stats"];  // STR DEX CON QUI INT PIE EMP CHA
		for (int i = 0; i < 8; i++) w.Byte((byte)(int)stats[i]);
		w.Bytes(new byte[43]);
		w.Byte((byte)(int)stats[2]);                  // constitution again
		w.Byte(0);
		Send(0xFF, w);
	}

	// 1.125+ deletion: the create packet with operation 3, no name and the cross-realm slot (HandleDeleteCharacterRequest).
	public void DeleteCharacter(int realm, int slot)
	{
		var w = new Writer();
		w.Byte((byte)(slot + (realm - 1) * 10));
		w.IntPascal("");
		w.Bytes(new byte[] { 0x18, 0, 0, 0 });
		w.Bytes(new byte[20]);                        // custom mode, face bytes, mood (none for a deletion)
		w.Byte(3);                                    // operation: delete
		w.Bytes(new byte[3]);
		w.Bytes(new byte[15]);
		w.Bytes(new byte[2]);                         // class, realm (none for a deletion)
		w.Bytes(new byte[3]);
		w.Bytes(new byte[8]);
		w.Bytes(new byte[45]);
		Send(0xFF, w);
	}

	// Entering the world as game.dll did: CharacterSelectRequest (login granted + session id again), RegionListRequest,
	// then WorldInitRequest with the character's cross-realm index - the server loads it, adds it to the world and sends
	// its position (PositionAndObjectID), inventory, skills, stats ...
	public void EnterWorld(int realm, int slot, string name)
	{
		int index = slot + (realm - 1) * 10;
		var w = new Writer();
		w.Byte((byte)index);
		w.Fixed(name, 28);
		Send(0x10, w);
		w = new Writer();
		w.Byte((byte)index);
		Send(0x9D, w);
		w = new Writer();
		w.Byte((byte)index);
		Send(0xD4, w);
	}

	// After a region change (RegionChanged) the client asks for the world again; the server adds the player there.
	public void WorldInitAgain()
	{
		var w = new Writer();
		w.Byte(0);
		Send(0xD4, w);
	}

	// PlayerInitRequest: the zone is loaded (the server sends the time, revives, starts regeneration ...).
	public void PlayerInit() => Send(0xE8, new Writer());

	// GameOpenRequest: flag 0 = no UDP (the server sends everything over TCP).
	public void GameOpen()
	{
		var w = new Writer();
		w.Byte(0);
		Send(0xBF, w);
	}

	// PlayerPositionUpdateHandler.HandlePacketSince1124 (+ the object id of 1.127): region coordinates as floats,
	// speed, fall speed, the zone, state flags, fall/ground word (bit 15 = on the ground), heading, action flags.
	public void Position(float x, float y, float z, float speed, float zSpeed, int zone, int state, bool onGround,
		int heading, int action, int health, int objectId)
	{
		var w = new Writer();
		w.FloatLE(x); w.FloatLE(y); w.FloatLE(z); w.FloatLE(speed); w.FloatLE(zSpeed);
		w.Short((ushort)SessionId);
		w.Short((ushort)objectId);
		w.Short((ushort)zone);
		w.Byte((byte)state);
		w.Byte(0);
		w.Short((ushort)(onGround ? 0x8000 : 0));
		w.Short((ushort)(heading & 0xFFF));
		w.Byte((byte)action);
		w.Bytes(new byte[2]);
		w.Byte((byte)health);
		w.Bytes(new byte[4]);
		Send(0xA9, w);
	}

	// PlayerHeadingUpdateHandler (1.127): turning in place.
	public void Heading(int heading, int target, int action, int state)
	{
		var w = new Writer();
		w.Short((ushort)SessionId);
		w.Short((ushort)target);
		w.Short((ushort)(heading & 0xFFF));
		w.Byte(0);
		w.Byte((byte)action);
		w.Byte(0);
		w.Byte((byte)(state >> 2));
		w.Bytes(new byte[2]);
		Send(0xBA, w);
	}

	// PlayerCommandHandler (1.127): one byte, then the text - "&command args" for a slash command, "&say text" for chat.
	public void Command(string text)
	{
		var w = new Writer();
		w.Byte(0);
		w.CString(text);
		Send(0xAF, w);
	}

	// PlayerTargetHandler: the target's object id (0 = none) and flags.
	public void Target(int objectId, int flags = 0)
	{
		var w = new Writer();
		w.Short((ushort)objectId);
		w.Short((ushort)flags);                       // 0x8000 examine, 0x4000 | 0x2000 target in view (PlayerTargetHandler)
		Send(0xB0, w);
	}

	// ObjectInteractRequestHandler: right-click / use on an object (your position, session, its id).
	public void Interact(int objectId, int x, int y)
	{
		var w = new Writer();
		w.Int((uint)x); w.Int((uint)y);
		w.Short((ushort)SessionId);
		w.Short((ushort)objectId);
		w.Short(0); w.Short(0);
		Send(0x7A, w);
	}

	// PlayerAttackRequestHandler: attack mode on / off (user action).
	public void Attack(bool start)
	{
		var w = new Writer();
		w.Byte((byte)(start ? 1 : 0));
		w.Byte(0);
		w.Short(0);
		Send(0x74, w);
	}

	// PlayerSitRequest
	public void Sit(bool sit)
	{
		var w = new Writer();
		w.Byte((byte)(sit ? 1 : 0));
		w.Bytes(new byte[3]);
		Send(0xC7, w);
	}

	// PlayerRegionChangeRequestHandler (1.126+): walking into a zone exit (its ZonePoint id).
	public void ZonePoint(int id)
	{
		var w = new Writer();
		w.ShortLE((ushort)id);
		w.Short(0);
		Send(0x90, w);
	}

	// The movement header UseSkill / UseSpell / UseSlot start with (1.124+): where you are and which way you face;
	// the flags say your target is in view (0xA000) and your ground target too (0x1000) - the server checks them.
	void UseHeader(Writer w, float x, float y, float z, float speed, int heading, bool targetInView)
	{
		w.FloatLE(x); w.FloatLE(y); w.FloatLE(z); w.FloatLE(speed);
		w.Short((ushort)(heading & 0xFFF));
		w.Short((ushort)(targetInView ? 0xB000 : 0x1000));
	}

	// UseSkillHandler: a skill by its place in your usable skills (type 1: counted from the first one that isn't a spec).
	public void UseSkill(float x, float y, float z, float speed, int heading, bool targetInView, int index, int type)
	{
		var w = new Writer();
		UseHeader(w, x, y, z, speed, heading, targetInView);
		w.Byte((byte)index);
		w.Byte((byte)type);
		Send(0xBB, w);
	}

	// TrainHandler (0x53): the trainer window's TRAIN. 8 spec codes (0xFFFFFFFF: none) and their levels in 64 bytes,
	// then 50 realm abilities by their place in the class's list (TrainerWindow code 1): the level to train it to.
	// PlayerTrainHandler: a specialization to a level by its place in the trainer window's list (the window's TRAIN,
	// as the client sent it - the typed /train looks the line up by its key, not the name the window shows).
	public void TrainSpec(int index, int level)
	{
		var w = new Writer();
		w.Int((uint)index);
		for (int i = 1; i < 8; i++) w.Int(0xFFFFFFFF);
		w.Int((uint)level);
		for (int i = 36; i < 64; i++) w.Byte(0);
		for (int i = 0; i < 50; i++) w.Int(0);
		Send(0x53, w);
	}

	public void TrainRealmAbility(int index, int level)
	{
		var w = new Writer();
		w.Int(0xFFFFFFFF);
		for (int i = 4; i < 64; i++) w.Byte(0);
		for (int i = 0; i < 50; i++) w.Int(i == index ? (uint)level : 0);
		Send(0x53, w);
	}

	// UseSpellHandler (1.124+): a spell by its line (index in the spell lines) and its level in that line.
	public void UseSpell(float x, float y, float z, float speed, int heading, bool targetInView, int level, int lineIndex)
	{
		var w = new Writer();
		UseHeader(w, x, y, z, speed, heading, targetInView);
		w.Byte((byte)level);
		w.Byte((byte)lineIndex);
		Send(0x7D, w);
	}

	// UseSlotHandler: use an item in a slot (type 0 = click: a weapon slot readies that weapon set; 1 = use).
	public void UseSlot(float x, float y, float z, float speed, int heading, bool targetInView, int slot, int type)
	{
		var w = new Writer();
		UseHeader(w, x, y, z, speed, heading, targetInView);
		w.Byte((byte)slot);
		w.Byte((byte)type);
		Send(0x71, w);
	}

	// PlayerMoveItemRequestHandler: move / swap / equip (slot numbers are the server's), count for stacks.
	public void MoveItem(int fromSlot, int toSlot, int count)
	{
		var w = new Writer();
		w.Short((ushort)SessionId);
		w.Short((ushort)toSlot);
		w.Short((ushort)fromSlot);
		w.Short((ushort)count);
		Send(0xDD, w);
	}

	// DestroyItemRequestHandler
	public void DestroyItem(int slot)
	{
		var w = new Writer();
		w.Int(0);
		w.Short((ushort)slot);
		w.Short(0);
		Send(0x80, w);
	}

	// PlayerSellRequestHandler: sell the item in a slot to the merchant you are talking to.
	public void SellItem(int x, int y, int slot)
	{
		var w = new Writer();
		w.Int((uint)x); w.Int((uint)y);
		w.Short((ushort)SessionId);
		w.Short((ushort)slot);
		Send(0x79, w);
	}

	// PlayerBuyRequestHandler: buy from the merchant window (its page / slot), count.
	public void BuyItem(int x, int y, int itemSlot, int count, int menu)
	{
		var w = new Writer();
		w.Int((uint)x); w.Int((uint)y);
		w.Short((ushort)SessionId);
		w.Short((ushort)itemSlot);
		w.Byte((byte)count);
		w.Byte((byte)menu);
		Send(0x78, w);
	}

	// DoorRequestHandler: a door clicked - the client's door id (zone x 1,000,000 + fixture x 100 + piece) and the
	// state wanted (1 open, 0 close); the server answers with DoorState (or opens / targets nothing).
	public void DoorRequest(long doorId, int state)
	{
		var w = new Writer();
		w.Int((uint)doorId);
		w.Byte((byte)state);
		w.Byte(0); w.Short(0);
		Send(0x99, w);
	}

	// PlayerGroundTargetHandler: your ground target (region units) and 0x100 = in view.
	public void GroundTarget(int x, int y, int z, int flag)
	{
		var w = new Writer();
		w.Int((uint)x); w.Int((uint)y); w.Int((uint)z);
		w.Short((ushort)flag);
		Send(0xEC, w);
	}

	// SiegeWeaponActionHandler: the siege window's buttons - 1 load (ammo slot), 2 arm, 3 aim, 4 fire, 5 move,
	// 6 repair, 7 salvage, 8 release, 9 stop, 10 swing (rams).
	public void SiegeCommand(int action, int ammo)
	{
		var w = new Writer();
		w.Short(0);
		w.Byte((byte)action); w.Byte((byte)ammo);
		Send(0xF5, w);
	}

	// WarmapShowRequestHandler: 0 the map page shown (0 Albion, 1 Midgard, 2 Hibernia), 1 send its keeps + fights.
	public void ShowWarmap(int code, int realmMap, int keepId)
	{
		var w = new Writer();
		w.Byte((byte)code); w.Byte((byte)realmMap); w.Byte((byte)keepId);
		Send(0x48, w);
	}

	// PlayerPickUpRequestHandler: pick up an object lying on the ground (your position, session, its id).
	public void PickUp(int x, int y, int objectId)
	{
		var w = new Writer();
		w.Int((uint)x); w.Int((uint)y);
		w.Short((ushort)SessionId);
		w.Short((ushort)objectId);
		Send(0xB5, w);
	}

	// DialogResponseHandler: the answer to a Dialog box (its data words and code back, 1 = yes / OK, 0 = no).
	public void DialogResponse(int data1, int data2, int data3, int code, int response)
	{
		var w = new Writer();
		w.Short((ushort)data1); w.Short((ushort)data2); w.Short((ushort)data3);
		w.Byte((byte)code);
		w.Byte((byte)response);
		w.Short(0);
		Send(0x82, w);
	}

	// QuestRemoveRequestHandler: abort a quest (its place in your quest list - the journal's index less one).
	public void RemoveQuest(int index)
	{
		var w = new Writer();
		w.Short(0); w.Short((ushort)index); w.Short(0); w.Short(0);
		Send(0x4F, w);
	}

	// PetWindowHandler: aggression (1-3), walk state (1 follow, 2 stay, 3 go target, 4 here), command (1 attack, 2 release).
	public void PetCommand(int aggro, int walk, int command)
	{
		var w = new Writer();
		w.Byte((byte)aggro); w.Byte((byte)walk); w.Byte((byte)command);
		w.Byte(0);
		Send(0x8A, w);
	}

	// PlayerTrainWindowHandler: the trainer window wherever you are (the client's own /train; the server answers with
	// SendTrainerWindow when you may train there - ALLOW_TRAIN_ANYWHERE).
	public void TrainWindow()
	{
		Send(0x7B, new Writer());
	}

	// RemoveConcentrationEffectHandler: cancel one of your concentration spells (its place in ConcentrationList).
	public void RemoveConcentration(int index)
	{
		var w = new Writer();
		w.Byte((byte)index);
		Send(0x76, w);
	}

	// PlayerDismountRequestHandler: off your steed (jump, /dismount).
	public void Dismount()
	{
		var w = new Writer();
		w.Short(0);
		Send(0xC8, w);
	}

	// DetailDisplayHandler: ask for an information text (1 inventory slot, 2 list spell line*100+level, 4 merchant
	// page*30+index, 6 style / 8 ability 100+place among the non-spec skills).
	public void Detail(int objectType, int objectId)
	{
		var w = new Writer();
		w.Short((ushort)objectType);
		w.Int(0);
		w.Short((ushort)objectId);
		Send(0xD8, w);
	}

	// PlayerMarketSearchRequestHandler (the Realm Exchange's search): the name's length, 3 bytes, the name, then the
	// filters - slot, three bonus (type, value) pairs as little-endian shorts, item ability, 1 byte, armour type, damage
	// type, level min / max, quality min, price min / max (copper, little-endian), crafted only, visual, page.
	public void MarketSearch(Godot.Collections.Dictionary s)
	{
		var w = new Writer();
		var name = Text1252.GetBytes(s.TryGetValue("name", out var nv) ? (string)nv : "");
		int n = Math.Min(name.Length, 63);
		w.Byte((byte)n);
		w.Byte(0); w.Byte(0); w.Byte(0);
		w.Bytes(name[..n]);
		int Get(string k, int def = 0) => s.TryGetValue(k, out var v) ? (int)v : def;
		w.Byte((byte)Get("slot"));
		for (int i = 1; i <= 3; i++)
		{
			w.ShortLE((ushort)Get("bonus" + i));
			w.ShortLE((ushort)Get("bonus" + i + "_value"));
		}
		w.Byte((byte)Get("proc"));
		w.Byte(0);
		w.Byte((byte)Get("armor"));
		w.Byte((byte)Get("damage"));
		w.Byte((byte)Get("level_min", 1));
		w.Byte((byte)Get("level_max", 52));
		w.Byte((byte)Get("quality_min"));
		w.IntLE((uint)Get("price_min"));
		w.IntLE((uint)Get("price_max"));
		w.Byte((byte)Get("crafted"));
		w.Byte((byte)Get("visual"));
		w.Byte((byte)Get("page"));
		Send(0x11, w);
	}

	// PlayerSetMarketPriceHandler: a listing's price - its place in the listing chest (0-99), 3 bytes, copper.
	public void SetMarketPrice(int place, long copper)
	{
		var w = new Writer();
		w.Byte((byte)place);
		w.Byte(0);
		w.Short(0);
		w.Int((uint)Math.Clamp(copper, 0, int.MaxValue));
		Send(0x1A, w);
	}

	// CheckLosResponseHandler: the answer to the server's line of sight question (0x100 = can see).
	public void LosReply(int source, int target, bool canSee)
	{
		var w = new Writer();
		w.Short((ushort)source);
		w.Short((ushort)target);
		w.Short((ushort)(canSee ? 0x100 : 0));
		w.Short(0);
		Send(0xD0, w);
	}

	// PingRequestHandler: 4 skipped bytes, then a timestamp the server echoes.
	public void Ping()
	{
		var w = new Writer();
		w.Int(0);
		w.Int((uint)Time.GetTicksMsec());
		w.Int(0);
		Send(0xA3, w);
	}

	// ---------------------------------------------------------------- sending

	public void Send(byte code, Writer data)
	{
		if (_stream == null) return;
		byte[] body = data.ToArray();
		var buf = new byte[10 + body.Length + 2];
		lock (_sendLock)
		{
			buf[0] = (byte)(body.Length >> 8);
			buf[1] = (byte)body.Length;
			buf[2] = (byte)(_sequence >> 8);
			buf[3] = (byte)_sequence;
			_sequence++;
			buf[4] = (byte)(SessionId >> 8);
			buf[5] = (byte)SessionId;
			buf[6] = 0;                                   // parameter
			buf[7] = 0;
			buf[8] = 0;                                   // code (the server reads the low byte)
			buf[9] = code;
			Buffer.BlockCopy(body, 0, buf, 10, body.Length);
			ushort sum = Checksum(buf, 0, buf.Length - 2);
			buf[^2] = (byte)(sum >> 8);
			buf[^1] = (byte)sum;
			try { _stream.Write(buf, 0, buf.Length); }
			catch (Exception e) { _inbox.Enqueue((-1, Text1252.GetBytes("send failed: " + e.Message))); }
		}
	}

	// PacketProcessor.CalculateChecksum
	public static ushort Checksum(byte[] packet, int offset, int size)
	{
		byte val1 = 0x7E, val2 = 0x7E;
		for (int i = offset; i < offset + size; i++)
		{
			val1 += packet[i];
			val2 += val1;
		}
		return (ushort)(val2 - ((val1 + val2) << 8));
	}

	// ---------------------------------------------------------------- receiving

	void ReadLoop()
	{
		var head = new byte[3];
		try
		{
			while (_tcp != null && _tcp.Connected)
			{
				if (!ReadExactly(head, 3)) break;
				int len = (head[0] << 8) | head[1];
				var data = new byte[len];
				if (len > 0 && !ReadExactly(data, len)) break;
				_inbox.Enqueue((head[2], data));
			}
		}
		catch (Exception e)
		{
			_inbox.Enqueue((-1, Text1252.GetBytes(e.Message)));
			return;
		}
		_inbox.Enqueue((-1, Text1252.GetBytes("the server closed the connection")));
	}

	bool ReadExactly(byte[] buf, int count)
	{
		int got = 0;
		while (got < count)
		{
			int n = _stream.Read(buf, got, count - got);
			if (n <= 0) return false;
			got += n;
		}
		return true;
	}

	public override void _Process(double delta)
	{
		while (_inbox.TryDequeue(out var p))
		{
			if (p.code < 0)
			{
				EmitSignal(SignalName.Disconnected, Text1252.GetString(p.data));
				Close();
				continue;
			}
			try { Handle(p.code, p.data); }
			catch (Exception e) { GD.PrintErr($"[net] packet 0x{p.code:X2} ({p.data.Length} bytes): {e.Message}"); }
		}
	}

	void Handle(int code, byte[] data)
	{
		var r = new Reader(data);
		switch (code)
		{
			case 0x22:                                    // CryptKey: the server's version reply (no key: unencrypted)
				break;
			case 0x2A:                                    // LoginGranted (PacketLib1127)
			{
				string account = r.Pascal();
				string server = r.Pascal();
				EmitSignal(SignalName.LoggedIn, account, server);
				break;
			}
			case 0x2C:                                    // LoginDenied: the error code (eLoginError)
				EmitSignal(SignalName.LoginFailed, (int)r.Byte());
				break;
			case 0x28:                                    // SessionID (little-endian)
				SessionId = r.ShortLE();
				EmitSignal(SignalName.Session, SessionId);
				break;
			case 0xFE:                                    // Realm: which realm the account may use (0 = any)
				EmitSignal(SignalName.Realm, (int)r.Byte());
				break;
			case 0xFC:                                    // CharacterOverview1126
				if (_wantRealms.TryDequeue(out int asked)) _lastRealm = asked;
				EmitSignal(SignalName.Characters, _lastRealm, ReadOverview(r));
				break;
			default:
				var d = ReadWorld(code, r);
				if (d != null)
					EmitSignal(SignalName.World, (string)d["kind"], d);
				else
					EmitSignal(SignalName.Packet, code, data);
				break;
		}
	}

	// The world packets (PacketLib168 ... 1127), decoded into dictionaries for the game: "kind" says which.
	static Godot.Collections.Dictionary ReadWorld(int code, Reader r)
	{
		var d = new Godot.Collections.Dictionary();
		switch (code)
		{
			case 0x21:                                    // DebugMode - or the companion raid window (CompanionRaid.Send:
				if (r.Left >= 44)                         // 128 bytes, marker 0x52, version 1)
				{
					r.Byte();
					if (r.Byte() != 0x52 || r.Byte() != 1) return null;
					d["kind"] = "raid";
					d["op"] = (int)r.Byte();              // 2 open (slot = capacity 40 / 80), 1 a slot, 3 close
					d["slot"] = (int)r.Byte();
					d["health"] = (int)r.Byte();
					d["power"] = (int)r.Byte();
					r.Byte();
					d["oid"] = r.ShortLE();
					r.Byte(); r.Byte();
					d["name"] = r.Fixed(32);
					return d;
				}
				// DebugMode: debug on / off, and the Offline server's observer flight (/fly - FlyCommandHandler,
				// PacketLib168.SendObserverFlightMode: 1 flying, 2 not, 0 a plain DebugMode)
				d["kind"] = "debug_mode";
				d["debug"] = r.Left > 0 ? (int)r.Byte() : 0;
				d["fly"] = r.Left > 0 ? (int)r.Byte() : 0;
				return d;
			case 0x20:                                    // PositionAndObjectID (1124): you, in the world
				d["kind"] = "you";
				d["x"] = r.FloatLE(); d["y"] = r.FloatLE(); d["z"] = r.FloatLE();
				d["oid"] = r.Short(); d["heading"] = r.Short();
				d["zone_x"] = r.Short(); d["zone_y"] = r.Short();   // dungeon zones: their offset in 8192 blocks
				d["region"] = r.Short();
				d["flags"] = (int)r.Byte();
				return d;
			case 0xDA:                                    // NPCCreate (1124): monsters, NPCs, the bots
				d["kind"] = "npc";
				d["oid"] = r.Short(); d["speed"] = (short)r.Short(); d["heading"] = r.Short();
				d["z"] = r.Short(); d["x"] = (long)r.Int(); d["y"] = (long)r.Int();
				d["speed_z"] = r.Short(); d["model"] = r.Short(); d["size"] = (int)r.Byte();
				d["level"] = (int)r.Byte(); d["flags"] = (int)r.Byte(); r.Byte();
				d["flags2"] = (int)r.Byte(); d["flags3"] = (int)r.Byte(); r.Short();
				d["name"] = r.Pascal(); d["guild"] = r.Pascal();
				return d;
			case 0x4B:                                    // PlayerCreate172 (1124): another player
				d["kind"] = "player";
				d["x"] = r.FloatLE(); d["y"] = r.FloatLE(); d["z"] = r.FloatLE();
				d["session"] = r.Short(); d["oid"] = r.Short(); d["heading"] = r.Short(); d["model"] = r.Short();
				d["level"] = (int)r.Byte(); d["flags"] = (int)r.Byte();
				var face = new Godot.Collections.Array();
				for (int i = 0; i < 7; i++) face.Add((int)r.Byte());
				d["face"] = face;
				r.Skip(3);
				d["name"] = r.Pascal(); d["guild"] = r.Pascal(); d["last_name"] = r.Pascal();
				d["prefix"] = r.Pascal(); d["title"] = r.Pascal();
				return d;
			case 0xA1:                                    // ObjectUpdate (168): a living's position (zone offsets), speed, health
			{
				d["kind"] = "move";
				int speed = r.Short(); int heading = r.Short();
				d["speed"] = speed & 0x0FFF;
				d["heading"] = heading & 0x0FFF;
				d["x"] = r.Short(); d["tx"] = r.Short(); d["y"] = r.Short(); d["ty"] = r.Short();
				d["z"] = r.Short(); d["tz"] = r.Short();
				d["oid"] = r.Short(); d["target"] = r.Short();
				d["health"] = (int)r.Byte();
				int flags = r.Byte();
				d["flags"] = flags;
				d["zone"] = r.Byte() | ((flags & 0x04) << 6);
				d["tzone"] = r.Byte() | ((flags & 0x08) << 5);
				return d;
			}
			case 0xA2:                                    // RemoveObject: gone from view (type 0 dead NPC, 1 NPC, 2 player)
				d["kind"] = "remove";
				d["oid"] = r.Short(); d["type"] = r.Short();
				return d;
			case 0xE1:                                    // ObjectDelete
				d["kind"] = "remove";
				d["oid"] = r.Short(); d["type"] = 9;
				return d;
			case 0xD9:                                    // ObjectCreate (176): world objects, items on the ground, doors
				d["kind"] = "object";
				d["oid"] = r.Short(); d["emblem"] = r.Short(); d["heading"] = r.Short(); d["z"] = r.Short();
				d["x"] = (long)r.Int(); d["y"] = (long)r.Int(); d["model"] = r.Short(); d["flags"] = r.Short();
				r.Int();
				d["name"] = r.Pascal();
				d["door"] = r.Byte() == 4 ? (long)r.Int() : -1L;
				return d;
			case 0x15:                                    // EquipmentUpdate (1124): what a living wears and holds
			{
				d["kind"] = "equipment";
				d["oid"] = r.Short();
				d["weapon_slots"] = (int)r.Byte();
				d["speed"] = (int)r.Byte();
				d["hidden"] = (int)r.Byte();          // 1 cloak hidden, 2 helm hidden
				d["hood"] = (int)r.Byte();
				int n = r.Byte();
				var items = new Godot.Collections.Array();
				for (int i = 0; i < n && r.Left > 0; i++)
				{
					int slot = r.Byte() & 0x7F;
					int model = r.Short();
					var it = new Godot.Collections.Dictionary { ["slot"] = slot, ["model"] = model & 0x1FFF };
					if (slot > 13 || slot < 10) it["extension"] = (int)r.Byte();
					if ((model & 0x8000) != 0) it["color"] = r.Short();
					else if ((model & 0x4000) != 0) it["color"] = (int)r.Byte();
					if ((model & 0x2000) != 0) it["effect"] = r.Short();
					items.Add(it);
				}
				d["items"] = items;
				return d;
			}
			case 0xAF:                                    // Message (1127): chat type, "@@" chat window / "##" popup, text
			{
				d["kind"] = "message";
				d["type"] = (int)r.Byte();
				string text = r.CString();
				d["popup"] = text.StartsWith("##");
				d["chat"] = text.StartsWith("@@");
				d["text"] = text.StartsWith("##") || text.StartsWith("@@") ? text[2..] : text;
				return d;
			}
			case 0xAD:                                    // CharacterStatusUpdate (190): your health, power, endurance
				d["kind"] = "status";
				d["health_pct"] = (int)r.Byte(); d["mana_pct"] = (int)r.Byte(); d["sitting"] = (int)r.Byte();
				d["endurance_pct"] = (int)r.Byte(); d["conc_pct"] = (int)r.Byte(); r.Byte();
				d["max_mana"] = r.Short(); d["max_endurance"] = r.Short(); d["max_conc"] = r.Short();
				d["max_health"] = r.Short(); d["health"] = r.Short(); d["endurance"] = r.Short();
				d["mana"] = r.Short(); d["conc"] = r.Short();
				return d;
			case 0x04:                                    // CharacterJump: the server moved you (same region)
				d["kind"] = "jump";
				d["x"] = (long)r.Int(); d["y"] = (long)r.Int(); d["oid"] = r.Short(); d["z"] = r.Short();
				d["heading"] = r.Short(); d["house"] = r.Short();
				return d;
			case 0xB7:                                    // RegionChanged: the server moved you to another region
				d["kind"] = "region_changed";
				d["region"] = r.Short();
				return d;
			case 0x7E:                                    // Time: the game's time of day
				d["kind"] = "time";
				d["time"] = (long)r.Int(); d["increment"] = (long)r.Int();
				return d;
			case 0xBC:                                    // CombatAnimation (186)
				d["kind"] = "combat";
				d["attacker"] = r.Short(); d["defender"] = r.Short(); d["weapon"] = r.Short(); d["shield"] = r.Short();
				d["style"] = r.ShortLE(); d["stance"] = (int)r.Byte(); d["result"] = (int)r.Byte();
				d["health"] = (int)r.Byte();
				return d;
			case 0x72:                                    // SpellCastAnimation: someone starts casting
				d["kind"] = "cast";
				d["caster"] = r.Short(); d["spell"] = r.Short(); d["time"] = r.Short();
				return d;
			case 0x1B:                                    // SpellEffectAnimation (174): a spell lands / fires
				d["kind"] = "spell_effect";
				d["caster"] = r.Short(); d["spell"] = r.Short(); d["target"] = r.Short(); d["bolt"] = r.Short();
				d["no_sound"] = (int)r.Byte(); d["success"] = (int)r.Byte();
				return d;
			case 0x73:                                    // InterruptSpellCast
				d["kind"] = "interrupt";
				d["caster"] = r.Short();
				return d;
			case 0xF9:                                    // EmoteAnimation
				d["kind"] = "emote";
				d["oid"] = r.Short(); d["emote"] = (int)r.Byte();
				return d;
			case 0xAE:                                    // PlayerDeath
				d["kind"] = "death";
				d["oid"] = r.Short(); d["killer"] = r.Short();
				return d;
			case 0xB6:                                    // MaxSpeed: your speed in percent
				d["kind"] = "max_speed";
				d["percent"] = r.Short(); d["no_turn"] = (int)r.Byte(); d["water"] = (int)r.Byte();
				return d;
			case 0xC9:                                    // SoundEffect (168): a client sound by its cc_sounds id - quest
				d["kind"] = "sound_effect";               // begun (7) / completed (11), bells, horns; zone + x / y / z +
				d["id"] = r.Short(); d["zone"] = r.Short();   // radius place it (all 0: just play it)
				d["x"] = r.Short(); d["y"] = r.Short(); d["z"] = r.Short(); d["radius"] = r.Short();
				return d;
			case 0x2B:                                    // CharacterInitFinished: the region is set up for you
				d["kind"] = "init_finished";
				return d;
			case 0x2D:                                    // GameOpenReply
				d["kind"] = "game_open";
				return d;
			case 0xA4:                                    // Quit: back to the character screen (or out)
				d["kind"] = "quit";
				d["mode"] = (int)r.Byte();
				return d;
			case 0xCC:                                    // DupNameCheckReply (1126)
				d["kind"] = "name_check";
				d["name"] = r.Fixed(24); d["result"] = (int)r.Byte();
				return d;
			case 0x89:                                    // PlayerRevive
				d["kind"] = "revive";
				d["oid"] = r.Short();
				return d;
			case 0x02:                                    // InventoryUpdate (189 + WriteItemData 1124): your items, by slot
			{
				d["kind"] = "inventory";
				int n = r.Byte();
				r.Byte();                                 // (shield shown)
				d["hidden"] = (int)r.Byte();              // 1 cloak hidden, 2 helm hidden
				d["hood"] = (int)r.Byte();
				d["weapon_slots"] = (int)r.Byte();        // VisibleActiveWeaponSlots
				d["window"] = (int)r.Byte();              // eInventoryWindowType
				var items = new Godot.Collections.Array();
				for (int i = 0; i < n && r.Left > 0; i++)
				{
					var it = ReadItem(r);
					items.Add(it);
				}
				d["items"] = items;
				return d;
			}
			case 0x12:                                    // MovingObjectCreate (168): siege weapons and boats - the 1124
			{                                             // NPCCreate sends GameMovingObjects this way. Read as an npc:
				d["kind"] = "npc";                        // position / health updates and removal are a living's
				d["oid"] = r.Short(); r.Short();
				d["heading"] = r.Short(); d["z"] = r.Short();
				d["x"] = (long)r.Int(); d["y"] = (long)r.Int();
				d["model"] = r.Short();
				int mflag = r.Short();                    // type | realm << 4 (0x40 Hibernia) | level << 9
				int mrealm = (mflag & 0x40) != 0 ? 3 : (mflag >> 4) & 3;
				d["flags"] = mrealm << 6; d["flags2"] = 0;
				d["level"] = (mflag >> 9) & 0x7F;
				d["emblem"] = r.Short(); r.Short(); r.Int();
				d["name"] = r.Pascal(); d["guild"] = "";
				d["size"] = 50; d["speed"] = 0;
				d["moving_object"] = true;
				return d;
			}
			case 0x99:                                    // DoorState (168): a door opened / closed by the server (keeps,
				d["kind"] = "door_state";                 // relic temples, every zone door) - the client's door id
				d["door_id"] = (long)r.Int(); d["open"] = r.Byte() == 1; d["flag"] = (int)r.Byte();
				return d;
			case 0xF6:                                    // ChangeTarget (168): the server picks your target - /target <name>,
				d["kind"] = "change_target";              // /assist; 0 = none (the client answers with its own Target packet)
				d["oid"] = (int)r.Short(); r.Short();
				return d;
			case 0xF5:                                    // SiegeWeaponInterface (1124): the siege weapon you control
			{
				int sflag = r.Short();
				r.Byte();
				int sclose = r.Byte();
				if (sclose == 1)                          // SendSiegeWeaponCloseInterface: 0, 1, then zeros
				{
					d["kind"] = "siege_close";
					return d;
				}
				d["kind"] = "siege_window";
				d["can_move"] = (sflag & 1) != 0; d["ammo_type"] = sflag >> 8;
				d["time"] = (int)r.Byte();                // tenths of a second left on the current action
				int scount = r.Byte();
				d["action"] = (int)r.Byte();              // SiegeTimer.eAction: 0 none, 1 aiming, 2 arming, 3 loading, 4 fire
				d["ammo_slot"] = (int)r.Byte();
				d["effect"] = r.Short(); r.Short(); r.Short();
				d["oid"] = r.Short();
				var ammo = new Godot.Collections.Array();
				for (int i = 0; i < scount && r.Left > 0; i++)
				{
					var a = new Godot.Collections.Dictionary();
					a["index"] = (int)r.Byte(); r.Short(); a["level"] = (int)r.Byte();
					r.Skip(3); a["object_type"] = (int)r.Byte(); r.Skip(2);
					a["count"] = (int)r.Byte(); r.Skip(5);
					a["model"] = r.Short(); r.Byte(); r.Short(); r.Byte(); r.Short();
					a["name"] = r.Pascal();
					ammo.Add(a);
				}
				d["ammo"] = ammo;
				d["name"] = r.Pascal();
				return d;
			}
			case 0xE3:                                    // SiegeWeaponAnimation (1124): aiming / arming / loading / firing
			{
				d["kind"] = "siege_anim";
				d["oid"] = (int)r.Int();
				d["x"] = (long)r.Int(); d["y"] = (long)r.Int(); d["z"] = (long)r.Int();
				d["target"] = (int)r.Int(); d["effect"] = r.Short(); d["timer"] = r.Short();
				d["action"] = (int)r.Byte(); d["target_health"] = (int)r.Byte();
				return d;
			}
			case 0x49:                                    // WarMapClaimedKeeps (1115): every keep's owner and state on the
			{                                             // war map page asked for, and who holds each relic
				d["kind"] = "warmap_keeps";
				r.Short();
				int keeps = r.Byte(), towers = r.Byte();
				var relics = new Godot.Collections.Array();
				for (int i = 0; i < 6; i++)               // alb / mid / hib strength, then alb / mid / hib magic: holder realm
					relics.Add((int)r.Byte());
				d["relics"] = relics;
				var list = new Godot.Collections.Array();
				for (int i = 0; i < keeps + towers && r.Left > 0; i++)
				{
					var k = new Godot.Collections.Dictionary();
					int id = r.Byte();                    // (map - 1) << 6 | index << 3 | tower
					k["map"] = (id >> 6) + 1; k["index"] = (id >> 3) & 7; k["tower"] = id & 7;
					int flag = r.Byte();
					k["realm"] = flag & 3; k["claimed"] = (flag & 0x04) != 0; k["siege"] = (flag & 0x08) != 0;
					k["teleport"] = (flag & 0x10) != 0;
					k["guild"] = r.Pascal();
					list.Add(k);
				}
				d["keeps"] = list;
				return d;
			}
			case 0x4A:                                    // WarMapDetailUpdate (170): fights and groups on the war map
			{
				d["kind"] = "warmap_fights";
				int fights = r.Byte(), groups = r.Byte();
				var fl = new Godot.Collections.Array();
				for (int i = 0; i < fights + groups && r.Left >= 4; i++)
				{
					var f = new Godot.Collections.Dictionary();
					f["zone"] = (int)r.Byte(); int pos = r.Byte(); f["x"] = pos >> 4; f["y"] = pos & 0x0F;
					f["color"] = (int)r.Byte(); f["size"] = (int)r.Byte(); f["group"] = i >= fights;
					fl.Add(f);
				}
				d["fights"] = fl;
				return d;
			}
			case 0xDB:                                    // ModelChange (168): a living's new model (shade, Vendo form, illusion)
				d["kind"] = "model_change";
				d["oid"] = r.Short(); d["model"] = r.Short(); d["size"] = (int)r.IntLE();
				return d;
			case 0x4C:                                    // VisualEffect (173): oid, effect (7 = quest indicator), value
				d["kind"] = "visual_effect";
				d["oid"] = r.Short(); d["effect"] = (int)r.Byte(); d["value"] = (int)r.Byte();
				return d;
			case 0x46:                                    // MinotaurRelicMapUpdate (186): the server's map markers - your
				d["kind"] = "map_marker";                 // realm's bots in your zone (AutonomousBotMapMarkers)
				d["id"] = (long)r.IntLE(); d["region"] = (int)r.IntLE();
				d["x"] = (int)r.IntLE(); d["y"] = (int)r.IntLE(); d["z"] = (int)r.IntLE();
				return d;
			case 0x45:                                    // MinotaurRelicMapRemove
				d["kind"] = "map_marker_remove";
				d["id"] = (long)r.IntLE();
				return d;
			case 0x7F:                                    // UpdateIcons (1110): your effect icons, changed entries only
			{
				d["kind"] = "icons";
				int n = r.Byte(); r.Byte(); r.Byte(); r.Byte();
				var list = new Godot.Collections.Array();
				for (int i = 0; i < n; i++)
				{
					var e = new Godot.Collections.Dictionary();
					e["index"] = (int)r.Byte(); r.Byte();
					e["immune"] = (int)r.Byte();
					e["icon"] = r.Short(); e["seconds"] = r.Short(); e["tooltip"] = r.Short();
					e["negative"] = (int)r.Byte();
					e["name"] = r.Pascal();
					list.Add(e);
				}
				d["list"] = list;
				return d;
			}
			case 0xFA:                                    // MoneyUpdate
				d["kind"] = "money";
				d["copper"] = (int)r.Byte(); d["silver"] = (int)r.Byte(); d["gold"] = r.Short();
				d["mithril"] = r.Short(); d["platinum"] = r.Short();
				return d;
			case 0x91:                                    // CharacterPointsUpdate (190): realm points, experience
				d["kind"] = "points";
				d["realm_points"] = (long)r.Int(); d["level_permill"] = r.Short(); d["spec_points"] = r.Short();
				d["bounty_points"] = (long)r.Int(); d["realm_spec_points"] = r.Short(); r.Short();
				d["xp"] = (long)r.LongLE(); d["xp_next"] = (long)r.LongLE();
				return d;
			case 0xD0:                                    // CheckLOSRequest: can the source see the target? (the client answers)
				d["kind"] = "los";
				d["source"] = r.Short(); d["target"] = r.Short();
				return d;
			case 0x17:                                    // MerchantWindow (1125): one page of a merchant's goods
			{
				d["kind"] = "merchant";
				int n = r.Byte();
				d["window"] = (int)r.Byte();
				d["page"] = (int)r.Byte();
				var items = new Godot.Collections.Array();
				for (int i = 0; i < n && r.Left > 0; i++)
				{
					var it = new Godot.Collections.Dictionary();
					it["index"] = (int)r.Byte();
					it["level"] = (int)r.Byte();
					it["value1"] = (int)r.Byte();
					it["spd_abs"] = (int)r.Byte();
					it["hand"] = r.Byte() >> 6;
					int type = r.Byte();
					it["type_damage"] = type >> 6;
					it["object_type"] = type & 0x3F;
					it["can_use"] = r.Byte() != 0;
					it["value2"] = r.ShortLE();
					it["price"] = (long)r.IntLE();
					it["model"] = r.ShortLE();
					it["name"] = r.IntPascal();
					items.Add(it);
				}
				d["items"] = items;
				return d;
			}
			case 0x1F:                                    // MarketExplorerWindow (1125): the Realm Exchange's search results
			{                                             // (a count of 255: the market window opens, nothing found yet)
				int n = r.Byte();
				if (n == 255)
				{
					d["kind"] = "market_open";
					return d;
				}
				d["kind"] = "market";
				d["page"] = (int)r.Byte();
				d["max_page"] = (int)r.Byte();
				r.Byte();
				var items = new Godot.Collections.Array();
				for (int i = 0; i < n && r.Left > 0; i++)
				{
					var it = new Godot.Collections.Dictionary();
					it["index"] = (int)r.Byte();
					it["level"] = (int)r.Byte();
					it["value1"] = (int)r.Byte();
					it["value2"] = (int)r.Byte();
					it["hand"] = r.Byte() >> 6;
					int type = r.Byte();
					it["type_damage"] = type >> 6;
					it["object_type"] = type & 0x3F;
					it["can_use"] = r.Byte() == 0;
					it["weight"] = r.ShortLE();
					it["condition"] = (int)r.Byte();
					it["durability"] = (int)r.Byte();
					it["quality"] = (int)r.Byte();
					it["bonus"] = (int)r.Byte();
					it["model"] = r.ShortLE();
					it["color"] = r.ShortLE();
					it["effect"] = r.ShortLE();
					it["lot"] = r.ShortLE();
					it["price"] = (long)r.IntLE();
					it["name"] = r.IntPascal();
					items.Add(it);
				}
				d["items"] = items;
				return d;
			}
			case 0x1E:                                    // ConsignmentMerchantMoney: the coins a consignment chest holds
			{
				long copper = r.Byte();
				long silver = r.Byte();
				long gold = r.Short();
				long mithril = r.Short();
				long platinum = r.Short();
				d["kind"] = "consign_money";
				d["copper"] = (((mithril * 1000 + platinum) * 1000 + gold) * 100 + silver) * 100 + copper;
				return d;
			}
			case 0x70:                                    // GroupMemberUpdate (1125): health / power / endurance by group place
			{
				d["kind"] = "group_update";
				var list = new Godot.Collections.Array();
				while (r.Left > 0)
				{
					int rec = r.Byte();
					if (rec == 0) break;
					int idx = rec & 0x1F;
					if ((rec & 0xE0) == 0x20)
						list.Add(new Godot.Collections.Dictionary { ["index"] = idx, ["hp"] = (int)r.Byte(),
							["power"] = (int)r.Byte(), ["end"] = (int)r.Byte(), ["status"] = (int)r.Byte() });
					else if ((rec & 0xE0) == 0x40) { r.Short(); r.Short(); r.Short(); }
					else if ((rec & 0xE0) == 0x80)        // the member's effect icons (PacketLib1125: a byte, then the icon)
					{
						int n = r.Byte();
						var memberIcons = new Godot.Collections.Array();
						for (int k = 0; k < n && r.Left >= 3; k++) { r.Byte(); memberIcons.Add(r.Short()); }
						list.Add(new Godot.Collections.Dictionary { ["index"] = idx, ["icons"] = memberIcons });
					}
					else break;
				}
				d["list"] = list;
				return d;
			}
			case 0xBD:                                    // Encumberance: carrying capacity and what you carry
				d["kind"] = "encumbrance";
				d["max"] = r.Short(); d["weight"] = r.Short();
				return d;
			case 0xC4:                                    // DetailWindow: an information text (delve, server news ...)
			{
				d["kind"] = "detail";
				d["mode"] = (int)r.Byte(); r.Byte();       // PacketLib181: two bytes before the caption (1 = statistics)
				d["caption"] = r.Pascal();
				var lines = new Godot.Collections.Array();
				int last = -1;
				while (r.Left > 1)
				{
					int n = r.Byte();
					if (n == 0) break;
					string t = r.Pascal();
					if (n == last && lines.Count > 0) lines[lines.Count - 1] = (string)lines[lines.Count - 1] + t;
					else lines.Add(t);
					last = n;
				}
				d["lines"] = lines;
				return d;
			}
			case 0xC8:                                    // Riding: a rider on (1) / off (0) a steed (bots on horse routes too)
				d["kind"] = "riding";
				d["rider"] = r.Short(); d["steed"] = r.Short(); d["mount"] = (int)r.Byte(); d["slot"] = (int)r.Byte();
				return d;
			case 0x88:                                    // PetWindow: your pet's window (2 open, 1 update, 0 close)
				d["kind"] = "pet_window";
				d["oid"] = r.Short(); r.Byte(); r.Byte();
				d["action"] = (int)r.Byte();
				d["aggro"] = (int)r.Byte();               // 1 aggressive, 2 defensive, 3 passive
				d["walk"] = (int)r.Byte();                // 1 follow, 2 stay, 3 go to target, 4 here
				r.Byte();
				var icons = new Godot.Collections.Array();   // the pet's effect icons (up to 8, no times)
				int count = r.Byte();
				for (int i = 0; i < count; i++) icons.Add(r.Short());
				d["icons"] = icons;
				return d;
			case 0x7B:                                    // TrainerWindow (1105): your trainer's window opens
			{
				// count, points, code (0 specs: the window opens; 1 the class's realm abilities; 4 / 5 skill names
				// and lists for the trainer's tooltips), 0
				int tcount = r.Byte();
				int points = r.Byte();
				int tcode = r.Byte();
				r.Byte();
				if (tcode == 1)
				{
					d["kind"] = "trainer_ra";
					d["points"] = points;                 // realm skill points to spend
					var list = new Godot.Collections.Array();
					for (int i = 0; i < tcount; i++)
					{
						var e = new Godot.Collections.Dictionary();
						e["index"] = (int)r.Byte();       // its place in the class's list (what training names)
						e["level"] = (int)r.Byte();
						e["cost"] = (int)r.Byte();        // the next level's cost
						string name = r.Pascal();
						bool ok = !(name.StartsWith("[") && name.EndsWith("]"));   // [name]: requirements not met
						e["name"] = ok ? name : name.Substring(1, name.Length - 2);
						e["available"] = ok;
						list.Add(e);
					}
					d["list"] = list;
				}
				else if (tcode == 0)
				{
					d["kind"] = "trainer";                // the trainable specializations: place, level, name
					d["points"] = points;
					var list = new Godot.Collections.Array();
					for (int i = 0; i < tcount && r.Left > 0; i++)
					{
						var e = new Godot.Collections.Dictionary();
						e["index"] = (int)r.Byte();
						e["level"] = (int)r.Byte();
						e["next"] = (int)r.Byte();
						e["name"] = r.Pascal();
						list.Add(e);
					}
					d["specs"] = list;
				}
				else
					d["kind"] = "trainer_more";
				return d;
			}
			case 0xD6:                                    // DisableSkills (168): reuse timers - abilities by their place
			{                                             // (code 1: index + seconds each), list spells (code 2: line +
				d["kind"] = "disable";                    // place in the line, one duration for all)
				int duration = r.Short();
				int tcount = r.Byte();
				int tcode = r.Byte();
				d["code"] = tcode;
				var list = new Godot.Collections.Array();
				for (int i = 0; i < tcount; i++)
				{
					if (tcode == 1)
					{
						int index = r.Short();
						list.Add(new Godot.Collections.Array { index, (int)r.Short() });
					}
					else
					{
						int line = r.Byte();
						list.Add(new Godot.Collections.Array { line, (int)r.Byte(), duration });
					}
				}
				d["list"] = list;
				return d;
			}
			case 0x81:                                    // Dialog (168): a yes / no or OK box from the server
				d["kind"] = "dialog";
				r.Byte();
				d["code"] = (int)r.Byte();
				d["data1"] = r.Short(); d["data2"] = r.Short(); d["data3"] = r.Short(); d["data4"] = r.Short();
				d["type"] = (int)r.Byte();                // 0 OK, 1 yes / no (a quest: 2 accept / decline, 1 finish)
				d["wrap"] = (int)r.Byte();
				if ((int)d["code"] == 0x21 || (int)d["code"] == 0x22)
				{
					// a quest offer (0x22) or its reward (0x21), PacketLib194.SendQuestWindow: name, summary, story
					d["quest"] = true;
					string qname = r.Pascal();
					string summary = r.Pascal();
					int storyLen = r.Short();
					d["title"] = qname;
					d["text"] = summary + "\n\n" + r.FixedRaw(storyLen);
				}
				else
					d["text"] = r.CString();
				return d;
			case 0xFB:                                    // StatsUpdate (175): your stats (STR DEX CON QUI INT PIE EMP CHA) - or,
			{                                             // with 0xFF at byte 72, your resists (SendCharResistsUpdate)
				bool resists = r.At(72) == 0xFF;
				int n = resists ? 9 : 8;                  // resists: crush slash thrust heat cold matter body spirit energy
				d["kind"] = resists ? "resists" : "stats";
				foreach (var key in new[] { "base", "buff", "item" })
				{
					var a = new Godot.Collections.Array();
					for (int i = 0; i < n; i++) a.Add((int)(short)r.Short());
					if (!resists) r.Short();
					d[key] = a;
				}
				foreach (var key in new[] { "cap", "ra" })
				{
					var a = new Godot.Collections.Array();
					for (int i = 0; i < n; i++) a.Add((int)r.Byte());
					if (!resists) r.Byte();
					d[key] = a;
				}
				r.Byte();                                 // the flag
				d["con_lost"] = (int)r.Byte();
				d["max_hp"] = r.Short();
				return d;
			}
			case 0x83:                                    // QuestEntry (1124): one line of your journal (no name: removed)
			{
				d["kind"] = "quest";
				d["index"] = (int)r.Byte();
				int nameLen = r.Byte();
				int b2 = r.Byte(), b3 = r.Byte();
				if (nameLen == 0) { d["name"] = ""; return d; }
				if (b2 == 0 && b3 == 0)
				{                                         // a RewardQuest: goals and level, then name, description
					int goalCount = r.Byte();
					d["level"] = (int)r.Byte();
					d["name"] = r.FixedRaw(nameLen);
					d["text"] = r.Pascal();
					var goals = new Godot.Collections.Array();   // its goals: text, done (a goal's item ends the read)
					for (int i = 0; i < goalCount && r.Left > 2; i++)
					{
						int len = r.ShortLE();
						var g = new Godot.Collections.Dictionary();
						g["text"] = r.FixedRaw(len).TrimEnd('\r', '\n');
						r.Skip(18);
						g["done"] = r.Byte() != 0;
						goals.Add(g);
						if (r.Byte() != 0) break;
					}
					d["goals"] = goals;
				}
				else
				{
					int descLen = b2 | (b3 << 8);
					r.Byte(); r.Byte();
					d["name"] = r.FixedRaw(nameLen);
					d["text"] = r.FixedRaw(descLen);
				}
				return d;
			}
			case 0x16:                                    // VariousUpdate: skills (1), spell lines (2), your character (3)
				return ReadVarious(r, d);
		}
		return null;
	}

	// WriteItemData (PacketLib1124): one inventory slot - all zeros (and no name) when the slot is empty.
	static Godot.Collections.Dictionary ReadItem(Reader r)
	{
		var it = new Godot.Collections.Dictionary();
		it["slot"] = (int)r.Byte();
		r.Short();                                    // unique id
		it["level"] = (int)r.Byte();
		it["value1"] = (int)r.Byte();
		it["value2"] = (int)r.Byte();
		it["hand"] = r.Byte() >> 6;
		int type = r.Byte();
		it["type_damage"] = type >> 6;
		it["object_type"] = type & 0x3F;
		r.Byte();
		it["weight"] = r.Short();
		it["condition"] = (int)r.Byte();
		it["durability"] = (int)r.Byte();
		it["quality"] = (int)r.Byte();
		it["bonus"] = (int)r.Byte();
		it["bonus_level"] = (int)r.Byte();
		it["model"] = r.Short();
		it["extension"] = (int)r.Byte();
		it["color"] = r.Short();
		int flag = r.Byte();
		if ((flag & 0x08) != 0) { it["spell1_icon"] = r.Short(); it["spell1"] = r.Pascal(); }
		if ((flag & 0x10) != 0) { it["spell2_icon"] = r.Short(); it["spell2"] = r.Pascal(); }
		it["effect"] = r.Short();
		it["name"] = r.Pascal();
		return it;
	}

	// VariousUpdate (PacketLib1112 / 179): subcode 1 = your usable skills in the server's order (specs, abilities, styles,
	// hybrid spells), 2 = the casters' spell lines (one per packet, footer subtype 99), 3 = your character's titles.
	static Godot.Collections.Dictionary ReadVarious(Reader r, Godot.Collections.Dictionary d)
	{
		int sub = r.Byte();
		if (sub == 6)
		{                                             // the group window (1125): every member, you included
			d["kind"] = "group";
			int members = r.Byte();
			var list = new Godot.Collections.Array();
			for (int i = 0; i < members && r.Left > 0; i++)
				list.Add(new Godot.Collections.Dictionary { ["name"] = r.Pascal(), ["class_name"] = r.Pascal(),
					["oid"] = r.Short(), ["level"] = (int)r.Byte() });
			d["members"] = list;
			return d;
		}
		int count = r.Byte();
		int subtype = r.Byte();
		int first = r.Byte();
		switch (sub)
		{
			case 1:
			{
				d["kind"] = "skills";
				d["first"] = first;
				d["more"] = subtype == 99;
				var list = new Godot.Collections.Array();
				for (int i = 0; i < count && r.Left > 0; i++)
				{
					var s = new Godot.Collections.Dictionary();
					s["level"] = (int)r.Byte();
					s["id"] = r.Short();
					s["page"] = (int)r.Byte();            // eSkillPage: 0 spec, 1 ability, 2 style, 3 spell, 4 song ...
					s["special"] = r.Short();
					s["bonus"] = (int)r.Byte();
					s["icon"] = r.Short();
					s["name"] = r.Pascal();
					list.Add(s);
				}
				d["list"] = list;
				return d;
			}
			case 2:
			{
				d["kind"] = "spell_line";
				d["done"] = subtype == 99;
				d["line"] = first;
				if (subtype == 99) return d;
				var spells = new Godot.Collections.Array();
				for (int i = 0; i < count && r.Left > 0; i++)
				{
					var s = new Godot.Collections.Dictionary();
					int lv = r.ShortLE();
					s["level"] = lv & 0xFF;
					s["kind"] = lv >= 512 ? "style" : (lv >= 256 ? "ability" : "spell");
					s["id"] = r.Short();
					s["icon"] = r.Short();
					s["name"] = r.Pascal();
					if (i == 0) d["name"] = s["name"];   // the first entry is the line itself
					else spells.Add(s);
				}
				d["spells"] = spells;
				return d;
			}
			case 3:
			{
				d["kind"] = "character";
				d["level"] = (int)r.Byte();
				d["name"] = r.Pascal();
				int hpHi = r.Byte();
				d["class_name"] = r.Pascal();
				d["max_health"] = (hpHi << 8) | r.Byte();
				d["profession"] = r.Pascal();
				r.Byte();
				d["title"] = r.Pascal();
				d["realm_level"] = (int)r.Byte();
				d["realm_title"] = r.Pascal();
				d["realm_spec_points"] = (int)r.Byte();
				d["base_class"] = r.Pascal();
				int houseHi = r.Byte();
				d["guild"] = r.Pascal();
				int houseLo = r.Byte();
				d["house"] = (houseHi << 8) | houseLo;
				d["last_name"] = r.Pascal();
				d["ml_level"] = Math.Max(0, (int)r.Byte() - 1);
				d["race_name"] = r.Pascal();
				// (PacketLib179) then the guild rank's title, the crafting skill and its title, the master level title
				if (r.Left > 0) { r.Byte(); d["guild_title"] = r.Pascal(); }
				if (r.Left > 0) { r.Byte(); d["craft_skill"] = r.Pascal(); }
				if (r.Left > 0) { r.Byte(); d["craft_title"] = r.Pascal(); }
				if (r.Left > 0) { r.Byte(); d["ml_title"] = r.Pascal(); }
				return d;
			}
			case 5:
			{                                             // SendUpdateWeaponAndArmorStats (1126): the character sheet's
				d["kind"] = "weapon_armor";               // weapon damage (x100), weapon skill and armor factor
				int Pair() { int hi = r.Byte(); r.Byte(); int lo = r.Byte(); r.Byte(); return (hi << 8) | lo; }
				d["weapon_damage"] = Pair() / 100.0;
				d["weapon_skill"] = Pair();
				d["armor_factor"] = Pair();
				return d;
			}
		}
		return null;
	}

	// PacketLib1126.SendCharacterOverview: four u32 flags, then ten slots - 0 for an empty one, else the character.
	static Godot.Collections.Array ReadOverview(Reader r)
	{
		var list = new Godot.Collections.Array();
		r.IntLE(); r.IntLE(); r.IntLE(); r.IntLE();
		for (int slot = 0; slot < 10 && r.Left > 0; slot++)
		{
			int level = r.Byte();
			if (level == 0) continue;
			var c = new Godot.Collections.Dictionary { ["slot"] = slot, ["level"] = level, ["name"] = r.IntPascal() };
			r.IntLE();                                    // 0x18
			r.Byte();                                     // always 1
			c["eye_size"] = (int)r.Byte();
			c["lip_size"] = (int)r.Byte();
			c["eye_color"] = (int)r.Byte();
			c["hair_color"] = (int)r.Byte();
			c["face"] = (int)r.Byte();
			c["hair_style"] = (int)r.Byte();
			c["ext_boots_gloves"] = (int)r.Byte();
			c["ext_torso_hood"] = (int)r.Byte();
			c["customisation_step"] = (int)r.Byte();
			c["mood"] = (int)r.Byte();
			r.Skip(13);
			c["location"] = r.IntPascal();
			c["class_name"] = r.IntPascal();
			c["race_name"] = r.IntPascal();
			c["model"] = r.ShortLE();
			c["region"] = (int)r.Byte();
			c["expansion"] = (int)r.Byte();
			var models = new Godot.Collections.Dictionary();
			models["helmet"] = r.ShortLE(); models["gloves"] = r.ShortLE(); models["boots"] = r.ShortLE();
			int rightHandColor = r.ShortLE();
			models["torso"] = r.ShortLE(); models["cloak"] = r.ShortLE(); models["legs"] = r.ShortLE(); models["arms"] = r.ShortLE();
			var colors = new Godot.Collections.Dictionary { ["right_hand"] = rightHandColor };
			colors["helmet"] = r.ShortLE(); colors["gloves"] = r.ShortLE(); colors["boots"] = r.ShortLE();
			colors["left_hand"] = r.ShortLE(); colors["torso"] = r.ShortLE(); colors["cloak"] = r.ShortLE();
			colors["legs"] = r.ShortLE(); colors["arms"] = r.ShortLE();
			models["right_hand"] = r.ShortLE(); models["left_hand"] = r.ShortLE(); models["two_hand"] = r.ShortLE(); models["distance"] = r.ShortLE();
			c["models"] = models;
			c["colors"] = colors;
			var stats = new Godot.Collections.Array();
			for (int i = 0; i < 8; i++) stats.Add((int)r.Byte());
			c["stats"] = stats;                           // STR DEX CON QUI INT PIE EMP CHA
			c["class_id"] = (int)r.Byte();
			c["realm"] = (int)r.Byte();
			int rg = r.Byte();
			c["race"] = ((rg >> 2) & 0x10) | (rg & 0x0F);
			c["gender"] = rg >> 7;
			c["weapon_slots"] = new Godot.Collections.Array { (int)r.Byte(), (int)r.Byte() };
			r.Byte();                                     // SI = 1, classic = 0
			r.Byte();                                     // constitution again
			r.Byte();
			list.Add(c);
		}
		return list;
	}

	// ---------------------------------------------------------------- byte helpers

	public sealed class Writer
	{
		readonly System.Collections.Generic.List<byte> _b = new();
		public void Byte(byte v) => _b.Add(v);
		public void Bytes(byte[] v) => _b.AddRange(v);
		public void Short(ushort v) { _b.Add((byte)(v >> 8)); _b.Add((byte)v); }
		public void ShortLE(ushort v) { _b.Add((byte)v); _b.Add((byte)(v >> 8)); }
		public void Int(uint v) { _b.Add((byte)(v >> 24)); _b.Add((byte)(v >> 16)); _b.Add((byte)(v >> 8)); _b.Add((byte)v); }
		public void IntLE(uint v) { _b.Add((byte)v); _b.Add((byte)(v >> 8)); _b.Add((byte)(v >> 16)); _b.Add((byte)(v >> 24)); }
		public void IntPascal(string s) { var b = Text1252.GetBytes(s ?? ""); IntLE((uint)b.Length); _b.AddRange(b); }
		public void Pascal(string s) { var b = Text1252.GetBytes(s ?? ""); Byte((byte)Math.Min(255, b.Length)); _b.AddRange(b[..Math.Min(255, b.Length)]); }
		public void Fixed(string s, int len) { var b = Text1252.GetBytes(s ?? ""); for (int i = 0; i < len; i++) _b.Add(i < b.Length ? b[i] : (byte)0); }
		public void CString(string s) { _b.AddRange(Text1252.GetBytes(s ?? "")); _b.Add(0); }
		public void FloatLE(float v) { var b = BitConverter.GetBytes(v); if (!BitConverter.IsLittleEndian) Array.Reverse(b); _b.AddRange(b); }
		public byte[] ToArray() => _b.ToArray();
	}

	public sealed class Reader
	{
		readonly byte[] _d;
		int _p;
		public Reader(byte[] d) { _d = d; }
		public int Left => _d.Length - _p;
		public int At(int offset) => _p + offset < _d.Length ? _d[_p + offset] : 0;   // a byte ahead, not read
		public byte Byte() => _p < _d.Length ? _d[_p++] : (byte)0;
		public void Skip(int n) => _p = Math.Min(_d.Length, _p + n);
		public int Short() { int v = (Byte() << 8) | Byte(); return v; }
		public int ShortLE() { int v = Byte() | (Byte() << 8); return v; }
		public uint Int() => ((uint)Byte() << 24) | ((uint)Byte() << 16) | ((uint)Byte() << 8) | Byte();
		public uint IntLE() => Byte() | ((uint)Byte() << 8) | ((uint)Byte() << 16) | ((uint)Byte() << 24);
		public float FloatLE() => BitConverter.Int32BitsToSingle((int)IntLE());
		public ulong LongLE() { ulong lo = IntLE(); ulong hi = IntLE(); return lo | (hi << 32); }
		public string Pascal() { int n = Byte(); return Str(n); }
		public string IntPascal() { int n = (int)IntLE(); return Str(n); }
		public string FixedRaw(int len) => Str(len);
		public string Fixed(int len) { var s = Str(len); int z = s.IndexOf('\0'); return z >= 0 ? s[..z] : s; }
		public string CString() { int s = _p; while (_p < _d.Length && _d[_p] != 0) _p++; var t = Text1252.GetString(_d, s, _p - s); if (_p < _d.Length) _p++; return t; }
		string Str(int n) { n = Math.Max(0, Math.Min(n, Left)); var s = Text1252.GetString(_d, _p, n); _p += n; return s; }
	}
}
