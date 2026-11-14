 -- RingSlingerPlus
 -- 2-RSP_Gametype.lua
 -- 12.07.2023
 -- Sirexer

RSP.GT = {}

freeslot('tol_HEADHUNT', 'tol_INSTAGIB', 'tol_HOTPOTATO', 'tol_DUEL')

//Gametypes RSP
table.insert(RSP.GT, {
    name = "FFA",
    identifier = "ffa",
    typeoflevel = TOL_MATCH,
	rules = GTR_RINGSLINGER|GTR_SPECTATORS|GTR_FIRSTPERSON|GTR_POWERSTONES|GTR_POINTLIMIT|GTR_TIMELIMIT|GTR_OVERTIME|GTR_HURTMESSAGES|GTR_RESPAWNDELAY|GTR_DEATHMATCHSTARTS|GTR_SPAWNINVUL|GTR_DEATHPENALTY,
    rankingtype = GT_MATCH,
	intermissiontype = int_match,
	headerleftcolor = 65,
    headerrightcolor = 66,
    description = "\x82\Free For All\x83 Match\x80 mode, play with\x83 all weapons\x80 and with\x83 pity shield\x80 after spawn! In this mode,\x83 you don't lose weapons\x80 after being hurt."
})

table.insert(RSP.GT, {
    name = "Team - FFA",
    identifier = "teamffa",
    typeoflevel = TOL_MATCH,
	rules = GTR_RINGSLINGER|GTR_SPECTATORS|GTR_FIRSTPERSON|GTR_POWERSTONES|GTR_POINTLIMIT|GTR_TIMELIMIT|GTR_OVERTIME|GTR_HURTMESSAGES|GTR_RESPAWNDELAY|GTR_DEATHMATCHSTARTS|GTR_SPAWNINVUL|GTR_TEAMS|GTR_DEATHPENALTY,
    rankingtype = GT_TEAMMATCH,
	intermissiontype = int_teammatch,
	headerleftcolor = 150,
    headerrightcolor = 38,
    description = "\x82\Free For All\x84 Team\x85 Match\x80 mode, play with\x83 all weapons\x80 and with\x83 pity shield\x80 after spawn! In this mode,\x83 you don't lose weapons\x80 after being hurt."
})

table.insert(RSP.GT, {
    name = "Hot Potato",
    identifier = "hotpotato",
    typeoflevel = TOL_HOTPOTATO|TOL_MATCH,
	rules = GTR_RINGSLINGER|GTR_SPECTATORS|GTR_FIRSTPERSON|GTR_HURTMESSAGES|GTR_RESPAWNDELAY|GTR_DEATHMATCHSTARTS,
    rankingtype = GT_MATCH,
	intermissiontype = int_match,
	headercolor = 83,
    description = "Avoid getting hit by\x82 IT\x80. If you're\x82 IT\x80, hit another player to giving \x82IT\x80 to another, before\x85 the bomb goes off\x80.\x83 Last Man Standing Wins."
})

table.insert(RSP.GT, {
    name = "HeadHunt",
    identifier = "headhunt",
    typeoflevel = TOL_HEADHUNT|TOL_MATCH,
	rules = GTR_RINGSLINGER|GTR_SPECTATORS|GTR_FIRSTPERSON|GTR_POINTLIMIT|GTR_TIMELIMIT|GTR_OVERTIME|GTR_RESPAWNDELAY|GTR_DEATHMATCHSTARTS|GTR_SPAWNINVUL|GTR_DEATHPENALTY,
    rankingtype = GT_MATCH,
	intermissiontype = int_match,
	headercolor = 45,
    description = "Everyone is hunting\x82 HeadHunt\x80, catch him to be \x83HeadHunt\x80. Every second\x82 HeadHunt\x83 gets score\x80."
})

table.insert(RSP.GT, {
    name = "Duel",
    identifier = "duel",
    typeoflevel = TOL_MATCH|TOL_DUEL,
	rules = GTR_RINGSLINGER|GTR_SPECTATORS|GTR_FIRSTPERSON|GTR_POINTLIMIT|GTR_TIMELIMIT|GTR_OVERTIME|GTR_HURTMESSAGES|GTR_RESPAWNDELAY|GTR_DEATHMATCHSTARTS|GTR_SPAWNINVUL|GTR_DEATHPENALTY,
    rankingtype = GT_MATCH,
	intermissiontype = int_match,
	headerleftcolor = 65,
    headerrightcolor = 66,
    description = "\x82\"1 VS 1\"\x80, just between you.\x83 Fight\x80 until\x85 the end\x80 of the match."
})

table.insert(RSP.GT, {
    name = "Duel Arena",
    identifier = "duelarena",
    typeoflevel = TOL_MATCH|TOL_DUEL,
	rules = GTR_RINGSLINGER|GTR_SPECTATORS|GTR_FIRSTPERSON|GTR_OVERTIME|GTR_HURTMESSAGES|GTR_RESPAWNDELAY|GTR_DEATHMATCHSTARTS|GTR_SPAWNINVUL|GTR_DEATHPENALTY,
	intermissiontype = int_match,
	headerleftcolor = 65,
    headerrightcolor = 66,
    description = "\x82\"1 VS 1\"\x80, with more than two players -\x83 the winner\x80 of the\x82 round\x80 plays with\x84 each player in queue\x80."
})

//Add RSP gametypes.
for i = 1, #RSP.GT do
	G_AddGametype(RSP.GT[i])
end

RSP.Gametypes = {
	["wfp_ignore"] = {
		GT_TAG,
		GT_HIDEANDSEEK
	},
	
	["ffa"] = {
		GT_FFA,
		GT_TEAMFFA
	},
	
	["instagib_ignore"] = {
		GT_HOTPOTATO,
		GT_HEADHUNT,
		GT_FFA,
		GT_TEAMFFA
	},
	
	["duel"] = {
		GT_DUEL,
		GT_DUELARENA
	},
	
	["1v1"] = {
		GT_DUEL,
		GT_DUELARENA
	}
	
}

//Hide & Seek gametypes.
rawset(_G, "G_IsHASGametype", function()
	if RSP.Gametypes["wfp_ignore"]
		if RSP.Gametypes["wfp_ignore"][1] == nil then return false end
		for i = 1, #RSP.Gametypes["wfp_ignore"] do
			if gametype == RSP.Gametypes["wfp_ignore"][i] then return true end
		end
	end
	return false
end)
//Free For All gametypes.
rawset(_G, "G_IsFFAGametype", function()
	if RSP.Gametypes["ffa"]
		if RSP.Gametypes["ffa"][1] == nil then return false end
		for i = 1, #RSP.Gametypes["ffa"] do
			if gametype == RSP.Gametypes["ffa"][i] then return true end
		end
	end
	return false
end)
//Gametypes that should not support instagib mode.
rawset(_G, "G_IsNoInstaGametype", function()
	if RSP.Gametypes["instagib_ignore"]
		if RSP.Gametypes["instagib_ignore"][1] == nil then return false end
		for i = 1, #RSP.Gametypes["instagib_ignore"] do
			if gametype == RSP.Gametypes["instagib_ignore"][i] then return true end
		end
	end
	return false
end)
//Duel gametypes.
rawset(_G, "G_IsDuelGametype", function()
	if RSP.Gametypes["duel"]
		if RSP.Gametypes["duel"][1] == nil then return false end
		for i = 1, #RSP.Gametypes["duel"] do
			if gametype == RSP.Gametypes["duel"][i] then return true end
		end
	end
	return false
end)
//1 versus 1 Gametypes.
rawset(_G, "G_Is1v1Gametype", function()
	if RSP.Gametypes["1v1"]
		if RSP.Gametypes["1v1"][1] == nil then return false end
		for i = 1, #RSP.Gametypes["1v1"] do
			if gametype == RSP.Gametypes["1v1"][i] then return true end
		end
	end
	return false
end)

rawset(_G, "RSP_AddIgnoreWFP", function(gametype)
	table.insert(RSP.Gametypes["wfp_ignore"], gametype)
end)

rawset(_G, "RSP_AddIgnoreInstagib", function(gametype)
	table.insert(RSP.Gametypes["instagib_ignore"], gametype)
end)

rawset(_G, "RSP_AddFFA", function(gametype)
	table.insert(RSP.Gametypes["ffa"], gametype)
end)

rawset(_G, "RSP_AddDuel", function(gametype)
	table.insert(RSP.Gametypes["duel"], gametype)
end)

rawset(_G, "RSP_Add1v1", function(gametype)
	table.insert(RSP.Gametypes["1v1"], gametype)
end)
