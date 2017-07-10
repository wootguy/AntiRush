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
CCVar@ g_timerMode;
CCVar@ g_disabled;

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
bool level_change_active = false;
CScheduledFunction@ constant_check = null;
CScheduledFunction@ change_trigger = null;
CScheduledFunction@ ten_sec_trigger = null;
string reason = "";

void init()
{
	if (!needs_init)
		return;
	if (g_disabled.GetBool())
	{
		reason = "disabled by cvar";
		return;
	}
	needs_init = false;
	level_change_active = false;
	populatePlayerStates();
	checkForChangelevel("trigger_changelevel");
	if (can_rush && !has_level_end_ent)
		checkForChangelevel("game_end");
}

EHandle changelevelEnt;
EHandle changelevelBut;

void getRushStats(int &out percentage, int &out neededPercent, int &out needPlayers)
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
	
	percentage = finished > 0 ? int((finished / total)*100.0) : 0;
	neededPercent = g_finishPercent.GetInt();
	needPlayers = int(ceil(float(neededPercent/100.0) * float(total)) - int(finished)); 
}

void doCountdown(string msg, int seconds)
{
	if (needs_init)
		return;
		
	if (seconds < 1)
	{
		g_PlayerFuncs.PrintKeyBindingStringAll("");
		return;
	}
		
	g_PlayerFuncs.PrintKeyBindingStringAll(msg + seconds + " seconds.");
	g_Scheduler.SetTimeout("doCountdown", 1, msg, seconds-1);
}

void checkEnoughPlayersFinished(CBasePlayer@ plr, bool printFinished=false)
{
	bool alternateMode = g_timerMode.GetBool();
	
	int percentage, neededPercent, needPlayers = 0;
	getRushStats(percentage, neededPercent, needPlayers);
	string plrTxt = needPlayers == 1 ? "player" : "players";
	
	bool isEnough = percentage >= neededPercent or (alternateMode and percentage > 0);
	bool everyoneFinished = percentage >= 100 or (alternateMode and percentage >= neededPercent);
	
	if (level_change_triggered and (everyone_finish_triggered or !everyoneFinished))
	{
		if (alternateMode and plr !is null)
		{
			if (everyoneFinished)
				g_PlayerFuncs.SayText(plr, "You finished the map.");
			else
				g_PlayerFuncs.SayText(plr, "You finished the map. " + needPlayers + " " + plrTxt + " needed for instant level change.");
		}
		return;
	}
	
	string msg = "";
	if (printFinished)
	{
		if (everyoneFinished && percentage >= 100)
		{
			msg = "" + plr.pev.netname + " finished the map. Everyone has finished now. ";
		}
		else
			msg = "" + plr.pev.netname + " finished the map. ";
	}
	else
		msg = "" + percentage + "% finished the map. ";
	
	if (isEnough or everyoneFinished)
	{
		CBaseEntity@ ent = changelevelEnt;
		float delay = everyoneFinished ? 3.0f : g_finishDelay.GetFloat();
		bool canTrigger = string(ent.pev.targetname).Length() > 0;
		if (canTrigger)
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
			doCountdown(canTrigger ? "Level changing in " : "Level change allowed in ", int(delay));
			@change_trigger = g_Scheduler.SetTimeout("triggerNextLevel", delay, @plr);
		}
			
		
		level_change_triggered = true;
	}
	else
		msg += "" + needPlayers + " " + plrTxt + " needed for level change.";	
	
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
		ent.pev.solid = SOLID_TRIGGER;
		if (string(ent.pev.targetname).Length() > 0)
			g_EntityFuncs.FireTargets(ent.pev.targetname, plr, plr, USE_TOGGLE);
		else
		{
			g_PlayerFuncs.SayTextAll(plr, "Level change trigger enabled. Reach the end of the map again to change levels.");
			ent.pev.solid = SOLID_TRIGGER;
			g_EntityFuncs.SetOrigin(ent, ent.pev.origin); // This fixes the random failures somehow. Thanks, Protector.
			level_change_active = true;
		}
	}
	else
		g_PlayerFuncs.SayTextAll(plr, "Something went horribly wrong (trigger_changelevel disappeared?). Level change failed.");	
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
			CBasePlayer@ plr = cast<CBasePlayer@>(ent);
			PlayerState@ state = getPlayerState(plr);
			
			if (state.finished)
			{
				ent.pev.solid = level_change_active ? SOLID_SLIDEBOX : SOLID_NOT;
				ent.pev.rendermode = kRenderTransTexture;
				ent.pev.renderamt = 128;
				//ent.pev.renderfx = kRenderFxHologram;
			}
			
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
									CBaseToggle@ toggle = cast<CBaseToggle@>(caller);
									string master = toggle.m_sMaster;
										
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
										keys["master"] = master;
										
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
										keys["master"] = master;
										
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
	@g_timerMode = CCVar("mode", 1, "0 = Timer starts when 'percent' of players finish. 1 = Timer starts when first player finishes", ConCommandFlag::AdminOnly);
	@g_disabled = CCVar("disabled", 0, "disables anti-rush for the current map", ConCommandFlag::AdminOnly);
}

void MapInit()
{
	g_Scheduler.SetTimeout("init", 2);
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


bool doCommand(CBasePlayer@ plr, const CCommand@ args)
{
	PlayerState@ state = getPlayerState(plr);
	
	if ( args.ArgC() > 0 )
	{
		if ( args[0] == ".rush" )
		{
			if (can_rush)
				g_PlayerFuncs.SayText(plr, "Anti-rush is disabled for this map (" + reason + ").");
			else
			{
				int percentage, neededPercent, needPlayers = 0;
				getRushStats(percentage, neededPercent, needPlayers);
				
			
				string plrTxt = needPlayers == 1 ? "player" : "players";
				string msg;
				if (g_timerMode.GetBool())
					msg = "Anti-rush is enabled for this map (" + neededPercent + "%). " + needPlayers + " " + plrTxt + " needed for instant level change.";
				else
					msg = "Anti-rush is enabled for this map (" + neededPercent + "%). " + needPlayers + " " + plrTxt + " needed to finish.";
					
				if (getPlayerState(plr).finished)
					msg += " You've finished already.";
				else
					msg += " You haven't finished yet.";
				g_PlayerFuncs.SayText(plr, msg);
			}
			return true;
		}
	}
	return false;
}

HookReturnCode ClientSay( SayParameters@ pParams )
{	
	CBasePlayer@ plr = pParams.GetPlayer();
	const CCommand@ args = pParams.GetArguments();
	
	if (doCommand(plr, args))
	{
		pParams.ShouldHide = true;
		return HOOK_HANDLED;
	}
	
	return HOOK_CONTINUE;
}

CClientCommand _rush("rush", "Anti-rush status", @consoleCmd );

void consoleCmd( const CCommand@ args )
{
	CBasePlayer@ plr = g_ConCommandSystem.GetCurrentPlayer();
	doCommand(plr, args);
}

void print(string text) { g_Game.AlertMessage( at_console, text); }
void println(string text) { print(text + "\n"); }