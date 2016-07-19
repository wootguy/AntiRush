class PlayerState
{
	EHandle plr;
	float time;
	bool finished;
	bool inGame; // player didn't leave
}

// persistent-ish player data, organized by steam-id or username if on a LAN server, values are @PlayerState
dictionary player_states;
bool debug_mode = false;

CCVar@ g_finishPercent;
CCVar@ g_finishDelay;

// Will create a new state if the requested one does not exit
PlayerState@ getPlayerState(CBasePlayer@ plr)
{
	string steamId = g_EngineFuncs.GetPlayerAuthId( plr.edict() );
	if (steamId == 'STEAM_ID_LAN' or steamId == 'BOT') {
		steamId = plr.pev.netname;
	}
	
	if ( !player_states.exists(steamId) )
	{
		PlayerState state;
		state.plr = plr;
		state.time = 0;
		state.finished = false;
		state.inGame = true;
		player_states[steamId] = state;
	}
	return cast<PlayerState@>( player_states[steamId] );
}

bool needs_init = true;
bool can_rush = true;
bool has_level_end_ent = false;
bool level_change_triggered = false;
bool everyone_finish_triggered = false;
CScheduledFunction@ constant_check = null;
CScheduledFunction@ change_trigger = null;
CScheduledFunction@ ten_sec_trigger = null;
string reason = "";

void init()
{
	if (!needs_init)
		return;
	needs_init = false;
	populatePlayerStates();
	checkForChangelevel("trigger_changelevel");
	if (can_rush && !has_level_end_ent)
		checkForChangelevel("game_end");
}

EHandle changelevelEnt;
EHandle changelevelBut;

void checkEnoughPlayersFinished(CBasePlayer@ plr, bool printFinished=false)
{
	array<string>@ stateKeys = player_states.getKeys();
	
	float total = 0;
	float finished = 0;
	for (uint i = 0; i < stateKeys.length(); i++)
	{
		PlayerState@ state = cast<PlayerState@>( player_states[stateKeys[i]] );
		CBaseEntity@ ent = state.plr;
		CBasePlayer@ p = cast<CBasePlayer@>(ent);
		Observer@ observer = p.GetObserver();
		if (state.inGame && !observer.IsObserver())
		{
			total++;
			if (state.finished)
				finished++;
		}
	}
	int percentage = finished > 0 ? int((finished / total)*100.0) : 0;
	int needed = g_finishPercent.GetInt();
	int needPlayers = int(ceil(float(needed/100.0) * float(total)) - int(finished)); 
	string plrTxt = needPlayers == 1 ? "player" : "players";
	
	bool everyoneFinished = percentage >= 100;
	
	if (level_change_triggered and (everyone_finish_triggered or !everyoneFinished))
		return;
	
	string msg = "";
	if (printFinished)
	{
		if (everyoneFinished)
			msg = "" + plr.pev.netname + " finished the map. Everyone has finished now. ";
		else
			msg = "" + plr.pev.netname + " finished the map. ";
	}
	else
		msg = "" + percentage + "% finished the map. ";
	
	bool isEnough = percentage >= needed;
	if (isEnough or everyoneFinished)
	{
		CBaseEntity@ ent = changelevelEnt;
		float delay = everyoneFinished ? 3.0f : g_finishDelay.GetFloat();
		if (string(ent.pev.targetname).Length() > 0)
			msg += "Level changing in " + delay + " seconds.";
		else
			msg += "Level change allowed in " + delay + " seconds.";
		
		if (everyoneFinished)
		{
			everyone_finish_triggered = true;
			g_Scheduler.SetTimeout("triggerNextLevel", 3.0f, @plr);
		}
		else
		{
			@change_trigger = g_Scheduler.SetTimeout("triggerNextLevel", delay, @plr);
			if (delay >= 20)
				@ten_sec_trigger = g_Scheduler.SetTimeout(@g_PlayerFuncs, "SayTextAll", delay-10, @plr, "Level changing in 10 seconds.");
		}
			
		
		level_change_triggered = true;
	}
	else
		msg += "" + needPlayers + " more " + plrTxt + " needed for level change.";	
	
	if (percentage == 0)
		return; // don't bother saying nobody finished
	g_PlayerFuncs.SayTextAll(plr, msg);
}

void triggerNextLevel(CBasePlayer@ plr)
{
	if (!level_change_triggered)
		return;
	if (changelevelBut)
	{
		CBaseEntity@ but = changelevelBut;
		g_EntityFuncs.FireTargets(but.pev.noise1, plr, but, USE_TOGGLE);
		//println("TRIGGER: " + but.pev.noise1);
	}
	else if (changelevelEnt)
	{
		CBaseEntity@ ent = changelevelEnt;
		if (string(ent.pev.targetname).Length() > 0)
			g_EntityFuncs.FireTargets(ent.pev.targetname, plr, plr, USE_TOGGLE);
		else
		{
			g_PlayerFuncs.SayTextAll(plr, "Level change trigger enabled. Reach the end of the map again to change levels.");
			ent.pev.solid = SOLID_TRIGGER;
		}
	}
	else
		println("Something went horribly wrong (trigger_changelevel disappeared). Level change aborted.");
}

void checkPlayerFinish()
{
	if (!changelevelEnt)
		return;
	CBaseEntity@ ent = null;
	do {
		@ent = g_EntityFuncs.FindEntityByClassname(ent, "player"); 
		if (ent !is null)
		{
			CBaseEntity@ changelevel = changelevelEnt;
			if (changelevel is null)
				return;
			
			Vector amin = ent.pev.mins + ent.pev.origin;
			Vector amax = ent.pev.maxs + ent.pev.origin;
			Vector bmin = changelevel.pev.mins + changelevel.pev.origin;
			Vector bmax = changelevel.pev.maxs + changelevel.pev.origin;
			
			bool touching = amax.x > bmin.x && amin.x < bmax.x &&
							amax.y > bmin.y && amin.y < bmax.y &&
							amax.z > bmin.z && amin.z < bmax.z;
			
			bool pressedBut = changelevelBut && ent.pev.iuser4 == 1337;
			
			if (touching or pressedBut)
			{
				CBasePlayer@ plr = cast<CBasePlayer@>(ent);
				PlayerState@ state = getPlayerState(plr);
				plr.pev.iuser4 = 0;
				if (!state.finished)
				{
					state.finished = true;
					int t = int(g_Engine.time);
					string mins = t / 60;
					int isecs = t % 60;
					string secs = isecs < 10 ? "0" + isecs : isecs;
					
					state.time = g_Engine.time - 1; // first second doesn't count since map is still loading
					//string msg = "" + ent.pev.netname + " finished the map in " + mins + ":" + secs;
					//g_PlayerFuncs.SayTextAll(plr, msg);
					checkEnoughPlayersFinished(@plr, true);
				}
			}
		}
	} while (ent !is null);
}

CBaseEntity@ getCaller(string name, bool recurse=true)
{
	bool found = false;
	CBaseEntity@ ent2 = null;
	CBaseEntity@ caller = null;
	do {
		@ent2 = g_EntityFuncs.FindEntityByClassname(ent2, "*"); 
		if (ent2 !is null && string(ent2.pev.targetname) != name && (ent2.HasTarget(name) or ent2.pev.target == name))
		{			
			if (ent2.pev.classname == "trigger_changelevel")
				continue;
			if (recurse && getCaller(ent2.pev.targetname, false) is null)
			{
				if (string(ent2.pev.classname).Find("func_") != 0 and string(ent2.pev.classname) != "trigger_once"
					and string(ent2.pev.classname) != "trigger_multiple")
				{
					//println("Found entity with no caller: " + ent2.pev.targetname + " (" + ent2.pev.classname + ")");
					continue;
				}
			}

			if (found)
			{
				//println("Multiple callers found " + ent2.pev.targetname + " (" + ent2.pev.classname + ") + " 
				//		+ caller.pev.targetname + " (" + caller.pev.classname + ")");
				return null; // don't handle multiple callers
			}
			found = true;
			@caller = @ent2;
		}
	} while (ent2 !is null);
	
	return caller;
}

void checkForChangelevel(string endLevelEntName="trigger_changelevel")
{
	bool found = has_level_end_ent = false;
	reason = "";
	can_rush = true;
	CBaseEntity@ ent = null;
	do {
		@ent = g_EntityFuncs.FindEntityByClassname(ent, endLevelEntName); 
		if (ent !is null)
		{
			if (found)
			{
				can_rush = true;
				reason = "multiple trigger_changelevels found";
				return;
			}
			found = true;
			bool isTriggered = (ent.pev.spawnflags & 2) != 0;
			string tname = ent.pev.targetname;

			// check for any entities that trigger this changelevel
			if (tname.Length() > 0)
			{
				CBaseEntity@ ent2 = null;
				do {
					@ent2 = g_EntityFuncs.FindEntityByClassname(ent2, "*"); 

					if (ent2 is null or ent2.pev.classname == endLevelEntName)
						continue;
						
					bool isSolidTrigger = ent2.pev.classname == "trigger_once" or ent2.pev.classname == "trigger_multiple";
					bool hasTrigger = ent2.HasTarget(tname) or ent2.pev.target == tname;
					hasTrigger = hasTrigger or ent2.pev.classname == "func_door" and ent2.pev.netname == tname;
					if ((isSolidTrigger or string(ent2.pev.targetname) != tname) && hasTrigger)
					{
						isTriggered = true;
						//println("UHHHHHHHHHH " + ent2.pev.targetname);
						if (string(ent2.pev.classname).Find("func_") != 0 or true)
						{
							//println("ANYTHING CALLS? " + ent2.pev.targetname);
							CBaseEntity@ caller;
							if (string(ent2.pev.targetname).Length() > 0)
								@caller = getCaller(ent2.pev.targetname);
							else
								@caller = @ent2;
							
							for (int i = 0; i < 64 && caller !is null; i++)
							{
								if (caller.pev.classname == "func_button" or caller.pev.classname == "trigger_once" or caller.pev.classname == "trigger_multiple")
									break;
								@caller = getCaller(caller.pev.targetname);
							}
							
							if (caller !is null)
							{
								//println("CALLER: " + caller.pev.classname);
								if (caller.pev.classname == "func_button" or caller.pev.classname == "trigger_once" or caller.pev.classname == "trigger_multiple")
								{
									if (caller.pev.classname == "func_button")
									{
										dictionary keys;
										keys["target"] = string("ANTIRUSH_PLAYER_FINISH");
										keys["noise1"] = string(caller.pev.target);
										keys["spawnflags"] = "1";
										keys["wait"] = "1";
										keys["model"] = string(caller.pev.model);
										keys["origin"] = caller.pev.origin.ToString();
										keys["angles"] = caller.pev.angles.ToString();
									
										CBaseButton@ button = cast<CBaseButton@>(caller);
										keys["master"] = string(button.m_sMaster);
										
										CBaseEntity@ newButton = g_EntityFuncs.CreateEntity("func_button", keys);
										changelevelBut = newButton;	
									}
									if (caller.pev.classname == "trigger_once" or caller.pev.classname == "trigger_multiple")
									{
										if (caller.pev.spawnflags & 2 != 0)
											continue; // dont handle triggers that clients arent meant to touch
										dictionary keys;
										keys["target"] = string("ANTIRUSH_PLAYER_FINISH");
										keys["noise1"] = string(caller.pev.target);
										keys["spawnflags"] = "16";
										keys["model"] = string(caller.pev.model);
										keys["origin"] = caller.pev.origin.ToString();
										keys["angles"] = caller.pev.angles.ToString();
										
										CBaseEntity@ newButton = g_EntityFuncs.CreateEntity("trigger_multiple", keys);
										changelevelBut = newButton;	
									}
										
									isTriggered = false;
									
									dictionary keys2;
									//keys["target"] = string(caller.pev.target);
									keys2["targetname"] = "ANTIRUSH_PLAYER_FINISH";
									keys2["target"] = "!activator";
									keys2["m_iszValueName"] = "iuser4";
									keys2["m_iszNewValue"] = "1337";
									keys2["m_iszValueType"] = "0";
									keys2["m_trigonometricBehaviour"] = "0";
									keys2["m_iAppendSpaces"] = "0";
										
									CBaseEntity@ changeVal = g_EntityFuncs.CreateEntity("trigger_changevalue", keys2);
									g_EntityFuncs.Remove(caller);
								}
							}
						}
						
					}
					/*
					if (ent2 !is null and (ent2.pev.classname == "env_laser" or ent2.pev.classname == "env_beam" or ent2.pev.classname == "env_spark" or ent2.pev.classname == "func_door"))
					{
						println("LOL BEAM");
						ent2.pev.targetname == "LOL_TEST";
						g_EntityFuncs.FireTargets(ent2.pev.targetname, null, null, USE_TOGGLE);
					}
					*/
				} while (ent2 !is null);	
			}			
			
			if (isTriggered)
			{
				// cant check multi_manager keys which is usually what triggers the next level
				if (reason.Length() == 0)
					reason = endLevelEntName + " sequence is too complex";
				can_rush = true;
				has_level_end_ent = true;
				return;
			}
			else if (tname.Length() == 0 and false)
			{
				// can't set a new targetname after it spawns
				reason = endLevelEntName + "has no targetname";
				can_rush = true;
				has_level_end_ent = true;
				return;
			}
			else
			{
				// it's a normal changelevel you just walk into
				ent.pev.solid = SOLID_NOT;
				changelevelEnt = ent;
				//ent.pev.targetname = "maprush_plugin_trigger";
				//g_EntityFuncs.DispatchKeyValue(ent.edict(), "targetname", "maprush_plugin_trigger");
				/*
				dictionary keys;
				keys["targetname"] = "maprush_copy_val";
				keys["target"] = "maprush_plugin_trigger";
				keys["m_iszValueName"] = "targetname";
				keys["m_iszNewValue"] = "maprush_plugin_trigger";
					
				CBaseEntity@ shootEnt = g_EntityFuncs.CreateEntity(classname, keys, false);	
				*/
				can_rush = false;
				has_level_end_ent = true;
				@constant_check = g_Scheduler.SetInterval("checkPlayerFinish", 0.05);
			}
		}
	} while (ent !is null);
	
	if (!found)
	{
		can_rush = true;
		reason = "no " + endLevelEntName + " in this map";
	}
}

void PluginInit()
{
	g_Module.ScriptInfo.SetAuthor( "w00tguy" );
	g_Module.ScriptInfo.SetContactInfo( "w00tguy123 - forums.svencoop.com" );
	
	g_Hooks.RegisterHook( Hooks::Player::ClientSay, @ClientSay );
	g_Hooks.RegisterHook( Hooks::Game::MapChange, @MapChange );
	g_Hooks.RegisterHook( Hooks::Player::ClientDisconnect, @ClientLeave );
	g_Hooks.RegisterHook( Hooks::Player::ClientPutInServer, @ClientJoin );
	
	debug_mode = true;
	
	g_Scheduler.SetTimeout("init", 0.5);
	
	@g_finishPercent = CCVar("percent", 75, "Percentage of players needed for level change", ConCommandFlag::AdminOnly);
	@g_finishDelay = CCVar("delay", 30.0f, "Seconds to wait before changing level", ConCommandFlag::AdminOnly);
}

void MapInit()
{
	g_Scheduler.SetTimeout("init", 0.5);
}

HookReturnCode MapChange()
{
	changelevelBut = null;
	changelevelEnt = null;
	needs_init = true;
	level_change_triggered = false;
	everyone_finish_triggered = false;
	player_states.deleteAll();
	g_Scheduler.RemoveTimer(constant_check);
	g_Scheduler.RemoveTimer(ten_sec_trigger);
	g_Scheduler.RemoveTimer(change_trigger);
	@ten_sec_trigger = null;
	@change_trigger = null;
	@constant_check = null;
	return HOOK_CONTINUE;
}

HookReturnCode ClientLeave(CBasePlayer@ plr)
{
	PlayerState@ state = getPlayerState(plr);
	state.inGame = false;
	g_Scheduler.SetTimeout("checkEnoughPlayersFinished", 2, @plr, false);
	return HOOK_CONTINUE;
}

HookReturnCode ClientJoin(CBasePlayer@ plr)
{
	if (plr is null)
		return HOOK_CONTINUE;
	PlayerState@ state = getPlayerState(plr);
	/*
	if (!state.inGame)
		println("" + plr.pev.netname + " rejoined after leaving");
	else
		println("" + plr.pev.netname + " joined for the first time");
	*/
	state.inGame = true;
	g_Scheduler.SetTimeout("checkEnoughPlayersFinished", 2, @plr, false);
	return HOOK_CONTINUE;
}

void populatePlayerStates()
{	
	CBaseEntity@ ent = null;
	do {
		@ent = g_EntityFuncs.FindEntityByClassname(ent, "player"); 
		if (ent !is null)
		{
			CBasePlayer@ plr = cast<CBasePlayer@>(ent);
			getPlayerState(plr);
			//println("TRY STATE FOR: " + plr.pev.netname);
		}
	} while (ent !is null);
}

HookReturnCode ClientSay( SayParameters@ pParams )
{
	CBasePlayer@ plr = pParams.GetPlayer();
	const CCommand@ pArguments = pParams.GetArguments();

	bool debug = true;
	
	if ( pArguments.ArgC() >= 1 )
	{
		if ( pArguments[0] == ".rush" )
		{
			if (can_rush)
				g_PlayerFuncs.SayText(plr, "Anti-rush does not work on this map (" + reason + ").");
			else
			{
				array<string>@ stateKeys = player_states.getKeys();
				float total = 0;
				float finished = 0;
				for (uint i = 0; i < stateKeys.length(); i++)
				{
					PlayerState@ state = cast<PlayerState@>( player_states[stateKeys[i]] );
					CBaseEntity@ ent = state.plr;
					CBasePlayer@ p = cast<CBasePlayer@>(ent);
					Observer@ observer = p.GetObserver();
					if (state.inGame && !observer.IsObserver())
					{
						total++;
						if (state.finished)
							finished++;
					}
				}
				
				int percentage = finished > 0 ? int((finished / total)*100.0) : 0;
				int needed = g_finishPercent.GetInt();
				int needPlayers = int(ceil(float(needed/100.0) * float(total)) - int(finished)); 
			
				string plrTxt = needPlayers == 1 ? "player" : "players";
				string msg = "Anti-rush is enabled for this map. " + needPlayers + " more " + plrTxt + " needed to finish.";
				if (getPlayerState(plr).finished)
					msg += " You've finished already.";
				else
					msg += " You haven't finished yet.";
				g_PlayerFuncs.SayText(plr, msg);
			}
			pParams.ShouldHide = true;
		}
	}
	
	return HOOK_CONTINUE;
}

void print(string text) { g_Game.AlertMessage( at_console, text); }
void println(string text) { print(text + "\n"); }

void te_explosion(Vector pos, string sprite="sprites/zerogxplode.spr", int scale=10, int frameRate=15, int flags=0, NetworkMessageDest msgType=MSG_BROADCAST, edict_t@ dest=null) { NetworkMessage m(msgType, NetworkMessages::SVC_TEMPENTITY, dest);m.WriteByte(TE_EXPLOSION);m.WriteCoord(pos.x);m.WriteCoord(pos.y);m.WriteCoord(pos.z);m.WriteShort(g_EngineFuncs.ModelIndex(sprite));m.WriteByte(scale);m.WriteByte(frameRate);m.WriteByte(flags);m.End(); }
void te_sprite(Vector pos, string sprite="sprites/zerogxplode.spr", uint8 scale=10, uint8 alpha=200, NetworkMessageDest msgType=MSG_BROADCAST, edict_t@ dest=null) { NetworkMessage m(msgType, NetworkMessages::SVC_TEMPENTITY, dest);m.WriteByte(TE_SPRITE);m.WriteCoord(pos.x); m.WriteCoord(pos.y);m.WriteCoord(pos.z);m.WriteShort(g_EngineFuncs.ModelIndex(sprite));m.WriteByte(scale); m.WriteByte(alpha);m.End();}
void te_beampoints(Vector start, Vector end, string sprite="sprites/laserbeam.spr", uint8 frameStart=0, uint8 frameRate=100, uint8 life=1, uint8 width=2, uint8 noise=0, Color c=GREEN, uint8 scroll=32, NetworkMessageDest msgType=MSG_BROADCAST, edict_t@ dest=null) { NetworkMessage m(msgType, NetworkMessages::SVC_TEMPENTITY, dest);m.WriteByte(TE_BEAMPOINTS);m.WriteCoord(start.x);m.WriteCoord(start.y);m.WriteCoord(start.z);m.WriteCoord(end.x);m.WriteCoord(end.y);m.WriteCoord(end.z);m.WriteShort(g_EngineFuncs.ModelIndex(sprite));m.WriteByte(frameStart);m.WriteByte(frameRate);m.WriteByte(life);m.WriteByte(width);m.WriteByte(noise);m.WriteByte(c.r);m.WriteByte(c.g);m.WriteByte(c.b);m.WriteByte(c.a);m.WriteByte(scroll);m.End(); }

class Color
{ 
	uint8 r, g, b, a;
	Color() { r = g = b = a = 0; }
	Color(uint8 r, uint8 g, uint8 b) { this.r = r; this.g = g; this.b = b; this.a = 255; }
	Color(uint8 r, uint8 g, uint8 b, uint8 a) { this.r = r; this.g = g; this.b = b; this.a = a; }
	Color(float r, float g, float b, float a) { this.r = uint8(r); this.g = uint8(g); this.b = uint8(b); this.a = uint8(a); }
	Color (Vector v) { this.r = uint8(v.x); this.g = uint8(v.y); this.b = uint8(v.z); this.a = 255; }
	string ToString() { return "" + r + " " + g + " " + b + " " + a; }
	Vector getRGB() { return Vector(r, g, b); }
}

Color RED    = Color(255,0,0);
Color GREEN  = Color(0,255,0);
Color BLUE   = Color(0,0,255);
Color YELLOW = Color(255,255,0);
Color ORANGE = Color(255,127,0);
Color PURPLE = Color(127,0,255);
Color PINK   = Color(255,0,127);
Color TEAL   = Color(0,255,255);
Color WHITE  = Color(255,255,255);
Color BLACK  = Color(0,0,0);
Color GRAY  = Color(127,127,127);