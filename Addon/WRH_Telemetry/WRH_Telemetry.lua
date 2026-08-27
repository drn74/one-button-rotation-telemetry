-- WRH Telemetry: addon INDIPENDENTE (non richiede One Button Rotation) per WoW 1.12.1, Fury
-- Warrior. Legge da solo lo stato del personaggio - stance, rage, HP, stack di Sunder Armor, ecc. -
-- con le stesse tecniche gia' verificate nel progetto One Button Rotation (vedi CLAUDE.md di quel
-- repo), e lo codifica in una fila di quadratini colorati ancorati in basso a sinistra dello
-- schermo, cosi' un programma esterno (screen-capture) puo' leggerlo e mostrarlo in una tabella
-- durante lo streaming.
--
-- Sola lettura, sempre: nessuna funzione qui dentro lancia una spell, switcha stance, attacca o
-- preme alcun tasto - solo GetXxx/UnitXxx e parsing testuale del combat log in entrata. L'unica
-- eccezione "morbida" e' il campo "ultima azione": se One Button Rotation E' installato E il suo
-- /wrh startlog e' attivo, viene letto (sola lettura di una SavedVariable) da WRH_DebugLogDB per
-- mostrare l'ultima azione REALMENTE eseguita da quell'addon - se assente, il campo resta vuoto,
-- il resto della telemetria funziona comunque.
--
-- Codifica colore: ogni pixel porta UN valore intero 0-16777215 (24 bit), spalmato sui tre canali
-- byte-alto/medio/basso -> R/G/B (value = R*65536 + G*256 + B). Ordine verificato sulla fonte reale
-- della tecnica (Xian55/WowClassicGrindBot, Addons/DataToColor/DataToColor.lua, funzione int():
-- R = band(rshift(value,16),255), G = band(rshift(value,8),255), B = band(value,255) - NON
-- low-byte-in-R come si potrebbe assumere, e' il contrario: R e' il byte piu' significativo).
-- Quella fonte usa la libreria bit (rshift/band, LuaJIT/Lua 5.1) - qui invece aritmetica pura
-- (math.floor + sottrazione), perche' in Lua 5.0 (1.12.1 vanilla) la libreria bit non e' garantita
-- disponibile (stesso genere di limite gia' documentato nel progetto principale). Vedi ValueToColor
-- sotto. Tutti i nostri valori attuali stanno comunque entro 0-255 (quindi R=G=0, B=valore quasi
-- sempre) - il redesign serve a seguire la tecnica corretta e a lasciare margine per valori piu'
-- grandi in futuro (es. HP/rage assoluti invece che percentuali), non per necessita' immediata.
--
-- Protocollo (vedi anche README.md nel repo, e reader/protocol.py sul lato Python - le due liste
-- DEVONO restare sincronizzate a mano, non c'e' generazione automatica):
-- indice 0  sync marker, sempre 16777215 (bianco puro, R=G=B=255) - il reader lo usa per verificare
--           l'allineamento del capture
-- indice 1  heartbeat, contatore 0-255 che avanza a ogni update - il reader lo usa per rilevare che
--           i dati sono "vivi" (se non cambia piu', l'addon non sta aggiornando: reload/logout/ecc.)
-- indice 2  stance: 0=nessuna, 1=Battle, 2=Berserker, 3=Defensive
-- indice 3  in combattimento: 0/1
-- indice 4  ha un target attaccabile: 0/1
-- indice 5  HP giocatore %: 0-100
-- indice 6  rage: 0-100
-- indice 7  HP target %: 0-100 (0 se nessun target)
-- indice 8  stack Sunder Armor sul target: 0-5
-- indice 9  Rend applicato sul target: 0/1
-- indice 10 Demoralizing Shout applicato sul target: 0/1
-- indice 11 finestra Overpower aperta: 0/1
-- indice 12 finestra Revenge aperta: 0/1
-- indice 13 attaccanti recenti (euristica multi-target): 0-99
-- indice 14 autoattack attivo: 0/1
-- indice 15 kind ultima azione loggata (solo se One Button Rotation logga): 0=nessuna, 1=stance, 2=spell, 3=attack
-- indice 16 id ultima azione loggata (vedi ACTION_IDS/STANCE_IDS sotto)
-- indice 17 target sta attaccando qualcun altro (per Taunt): 0/1
-- indice 18 knownMask: bitmask spell conosciute, un bit per abilita' (bit per id N = 2^(N-1),
--           stessa numerazione di ACTION_IDS - id 1-4 = Auto Attack/stance, mai impostati qui)
-- indice 19 readyMask: bitmask spell castabili ORA (cooldown pronto + rage sufficiente), stessi bit
--           di knownMask - usate dal reader Python (reader/rotation.py) per calcolare "quale
--           azione sceglierebbe la priority list dell'addon originale ORA", senza eseguire nulla
--           in game: e' solo un calcolo su numeri gia' ricevuti, mostrato come testo in console.
-- indice 20 checksum: somma degli indici 1-19 modulo 16777216 - il reader la ricalcola dai valori
--           letti e scarta il frame se non torna (capture a meta' di un aggiornamento: raro, dato
--           che WoW disegna un intero frame in un colpo solo, ma non impossibile - es. un altro
--           addon che disegna sopra per un istante, o un frame drop durante la cattura). Il sync
--           marker (indice 0) copre solo l'allineamento, l'heartbeat (indice 1) solo la vivacita' -
--           nessuno dei due garantisce da solo che QUESTO frame specifico sia internamente coerente.

WRHT = {}
WRHT.commands = {}

local NUM_SQUARES = 21
-- 1 pixel fisico per valore (riga di 21px totali, quasi invisibile). Nessun margine di errore
-- sull'allineamento: se il reader campiona anche solo 1px fuori posto legge il valore sbagliato
-- senza errori visibili - va calibrato con precisione (vedi README.md). Con un valore piu' alto
-- (es. 4) il reader campiona il pixel centrale di ogni blocco, tollerando piccoli errori di
-- posizionamento - scelta deliberata dell'utente di rinunciare a quel margine per un footprint
-- minimo.
local SQUARE_SIZE = 1
local UPDATE_INTERVAL = 0.2 -- secondi tra un aggiornamento e l'altro (5 Hz, sufficiente per uno stream)

-- Stessa mappatura di STANCE_IDS/ACTION_IDS/ACTION_KIND_IDS deve esistere in reader/protocol.py.
local STANCE_IDS = {
	["Battle Stance"] = 1,
	["Berserker Stance"] = 2,
	["Defensive Stance"] = 3,
}

local ACTION_KIND_IDS = {
	stance = 1,
	spell = 2,
	attack = 3,
}

local ACTION_IDS = {
	["Auto Attack"] = 1,
	["Battle Stance"] = 2,
	["Berserker Stance"] = 3,
	["Defensive Stance"] = 4,
	["Bloodrage"] = 5,
	["Charge"] = 6,
	["Intimidating Shout"] = 7,
	["Execute"] = 8,
	["Overpower"] = 9,
	["Taunt"] = 10,
	["Bloodthirst"] = 11,
	["Whirlwind"] = 12,
	["Shield Slam"] = 13,
	["Revenge"] = 14,
	["Sunder Armor"] = 15,
	["Rend"] = 16,
	["Thunder Clap"] = 17,
	["Heroic Strike"] = 18,
	["Cleave"] = 19,
	["Demoralizing Shout"] = 20,
}

-- Inversa di ACTION_IDS (id -> nome), costruita una volta sola - serve a ComputeSpellMasks sotto
-- per sapere quale nome di spell corrisponde a ciascun bit (bit per id N = 2^(N-1)). Gli id 1-4
-- (Auto Attack/le tre stance) non sono vere spell, restano semplicemente senza bit impostato nelle
-- maschere - ComputeSpellMasks li salta esplicitamente.
local ACTION_NAMES_BY_ID = {}
for name, id in pairs(ACTION_IDS) do
	ACTION_NAMES_BY_ID[id] = name
end

--------------------------------------------------------------------------------
-- Spellbook scan (copia minimale di SpellbookScan.lua di One Button Rotation) -
-- serve solo a risolvere nome spell -> texture, per riconoscere i debuff Sunder
-- Armor/Rend/Demoralizing Shout sul target via UnitDebuff (che ritorna solo la
-- texture dell'icona, mai il nome - stesso limite gia' documentato nel progetto
-- principale).
--------------------------------------------------------------------------------

local spellIndex = {}

local function ScanSpellbook()
	local index = {}
	local numTabs = GetNumSpellTabs()

	for tab = 1, numTabs do
		local _, _, offset, numSpells = GetSpellTabInfo(tab)
		for i = offset + 1, offset + numSpells do
			local spellName = GetSpellName(i, BOOKTYPE_SPELL)
			if spellName then
				index[spellName] = i
			end
		end
	end

	spellIndex = index
end

local spellbookFrame = CreateFrame("Frame", "WRHT_SpellbookFrame")
spellbookFrame:RegisterEvent("PLAYER_LOGIN")
spellbookFrame:RegisterEvent("LEARNED_SPELL_IN_TAB")
spellbookFrame:RegisterEvent("SPELLS_CHANGED")
spellbookFrame:SetScript("OnEvent", ScanSpellbook)
ScanSpellbook() -- scansione immediata al caricamento (utile su /reload mentre gia' in game)

local function GetSpellTextureByName(name)
	local index = spellIndex[name]
	if not index then
		return nil
	end
	return GetSpellTexture(index, "spell")
end

--------------------------------------------------------------------------------
-- Debuff/stack sul target (copia di ScanTargetDebuff/GetSunderArmorStacks/
-- IsRendAppliedOnTarget/IsDemoralizingShoutAppliedOnTarget da Rotation.lua).
--------------------------------------------------------------------------------

local function ScanTargetDebuff(spellName)
	local targetTexture = GetSpellTextureByName(spellName)
	if not targetTexture then
		return false, 0
	end

	for i = 1, 16 do
		local texture, stack = UnitDebuff("target", i)
		if not texture then
			break
		end
		if texture == targetTexture then
			return true, stack or 1
		end
	end

	return false, 0
end

local function GetSunderArmorStacks()
	local found, stack = ScanTargetDebuff("Sunder Armor")
	return found and stack or 0
end

local function IsRendAppliedOnTarget()
	return ScanTargetDebuff("Rend")
end

local function IsDemoralizingShoutAppliedOnTarget()
	return ScanTargetDebuff("Demoralizing Shout")
end

--------------------------------------------------------------------------------
-- Stance (copia di GetCurrentStance da StanceCheck.lua).
--------------------------------------------------------------------------------

local function GetCurrentStance()
	local numForms = GetNumShapeshiftForms()
	for i = 1, numForms do
		local _, formName, isActive = GetShapeshiftFormInfo(i)
		if isActive then
			return formName
		end
	end
	return nil
end

--------------------------------------------------------------------------------
-- Target attaccabile (copia di WRH.HasAttackableTarget da Rotation.lua).
--------------------------------------------------------------------------------

local function HasAttackableTarget()
	return UnitExists("target") and UnitCanAttack("player", "target") and not UnitIsDead("target")
end

-- Serve solo a Taunt (Defensive/Tank): il target attuale sta attaccando qualcun altro? Copia di
-- IsTargetAttackingSomeoneElse da Rotation.lua - stesso limite gia' documentato nel progetto
-- principale: il token "targettarget" non e' ancora stato verificato in game su questo server, se
-- non supportato questa funzione ritorna semplicemente false (degrado sicuro).
local function IsTargetAttackingSomeoneElse()
	return UnitExists("targettarget") and not UnitIsUnit("targettarget", "player")
end

--------------------------------------------------------------------------------
-- Castabilita' (copia di GetSpellRageCost/IsSpellReady/IsSpellCastableNow da Rotation.lua): serve
-- a calcolare, per ogni abilita' rilevante alla rotazione, se e' conosciuta e se e' castabile ORA
-- (cooldown pronto + rage sufficiente). Sola lettura: GetSpellCooldown e il tooltip scan non hanno
-- alcun effetto di gioco, esattamente come nel progetto principale - IsUsableSpell non esiste in
-- 1.12.1, il costo in rage va letto dal tooltip.
--------------------------------------------------------------------------------

local scanTooltip = CreateFrame("GameTooltip", "WRHT_ScanTooltip", nil, "GameTooltipTemplate")
scanTooltip:SetOwner(UIParent, "ANCHOR_NONE")

local function GetSpellRageCost(index)
	scanTooltip:ClearLines()
	scanTooltip:SetSpell(index, "spell")

	for i = 2, scanTooltip:NumLines() do
		local line = getglobal("WRHT_ScanTooltipTextLeft" .. i)
		local text = line and line:GetText()
		if text then
			local _, _, cost = string.find(text, "(%d+) Rage")
			if cost then
				return tonumber(cost)
			end
		end
	end

	return 0
end

local function IsSpellReady(index)
	local start, duration = GetSpellCooldown(index, "spell")
	if not start or start == 0 then
		return true
	end
	return GetTime() > start + duration
end

local function IsSpellCastableNow(name)
	local index = spellIndex[name]
	if not index then
		return false
	end
	if not IsSpellReady(index) then
		return false
	end

	local rageCost = GetSpellRageCost(index)
	local currentRage = UnitMana("player")
	return currentRage >= rageCost
end

-- Calcola le due bitmask (conosciute/pronte ORA) su tutte le vere spell della rotazione (id 5-20,
-- id 1-4 sono Auto Attack/stance, saltati). Un bit per spell, bit per id N = 2^(N-1) - stessa
-- numerazione di ACTION_IDS, cosi' il lato Python puo' decodificarle senza una tabella separata.
-- Il reader Python usa queste maschere per replicare l'ordine della priority list di
-- Rotation.lua/GetNextAction SENZA eseguire nulla in game (e' solo testo mostrato in console) -
-- vedi reader/rotation.py.
local function ComputeSpellMasks()
	local known, ready = 0, 0
	local bitValue = 1
	for id = 1, 20 do
		local name = ACTION_NAMES_BY_ID[id]
		if name and id >= 5 then
			if spellIndex[name] then
				known = known + bitValue
				if IsSpellCastableNow(name) then
					ready = ready + bitValue
				end
			end
		end
		bitValue = bitValue * 2
	end
	return known, ready
end

--------------------------------------------------------------------------------
-- Finestra Overpower (copia della logica in Rotation.lua: 4 secondi dopo una
-- schivata nemica, rilevata via parsing testuale del combat log - nessuna API
-- diretta disponibile in 1.12.1).
--------------------------------------------------------------------------------

local OVERPOWER_WINDOW_SECONDS = 4
local overpowerReadyUntil = 0

local overpowerFrame = CreateFrame("Frame", "WRHT_OverpowerFrame")
overpowerFrame:RegisterEvent("CHAT_MSG_COMBAT_SELF_MISSES")
overpowerFrame:RegisterEvent("CHAT_MSG_SPELL_SELF_DAMAGE")
overpowerFrame:RegisterEvent("CHAT_MSG_SPELL_DAMAGESHIELDS_ON_SELF")
overpowerFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
overpowerFrame:SetScript("OnEvent", function()
	if event == "PLAYER_TARGET_CHANGED" then
		overpowerReadyUntil = 0
		return
	end
	if (string.find(arg1, "You attack") and string.find(arg1, "dodges")) or string.find(arg1, "was dodged by") then
		overpowerReadyUntil = GetTime() + OVERPOWER_WINDOW_SECONDS
	end
end)

local function IsOverpowerWindowOpen()
	return GetTime() < overpowerReadyUntil
end

--------------------------------------------------------------------------------
-- Finestra Revenge (copia della logica in Rotation.lua: 4 secondi dopo che IL
-- GIOCATORE subisce un parry/dodge/block).
--------------------------------------------------------------------------------

local REVENGE_WINDOW_SECONDS = 4
local revengeReadyUntil = 0

local revengeFrame = CreateFrame("Frame", "WRHT_RevengeFrame")
revengeFrame:RegisterEvent("CHAT_MSG_COMBAT_CREATURE_VS_SELF_MISSES")
revengeFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
revengeFrame:SetScript("OnEvent", function()
	if event == "PLAYER_TARGET_CHANGED" then
		revengeReadyUntil = 0
		return
	end
	if string.find(arg1, "You dodge") or string.find(arg1, "You parry") or string.find(arg1, "You block") then
		revengeReadyUntil = GetTime() + REVENGE_WINDOW_SECONDS
	end
end)

local function IsRevengeWindowOpen()
	return GetTime() < revengeReadyUntil
end

--------------------------------------------------------------------------------
-- Attaccanti recenti / euristica multi-target (copia della logica in
-- Rotation.lua: conta i nomi distinti che hanno colpito il giocatore negli
-- ultimi 5 secondi, via parsing del combat log - nessun range-scan disponibile
-- in 1.12.1).
--------------------------------------------------------------------------------

local MULTI_TARGET_WINDOW_SECONDS = 5
local recentAttackers = {}

local function RecordAttacker(name)
	if name and name ~= "" then
		recentAttackers[name] = GetTime()
	end
end

local function CountRecentAttackers()
	local now = GetTime()
	local count = 0
	for name, seenAt in pairs(recentAttackers) do
		if now - seenAt > MULTI_TARGET_WINDOW_SECONDS then
			recentAttackers[name] = nil
		else
			count = count + 1
		end
	end
	return count
end

local function ExtractAttackerName(msg, suffix)
	local pos = string.find(msg, suffix, 1, true)
	if not pos then
		return nil
	end
	return string.sub(msg, 1, pos - 1)
end

local multiTargetFrame = CreateFrame("Frame", "WRHT_MultiTargetFrame")
multiTargetFrame:RegisterEvent("CHAT_MSG_COMBAT_CREATURE_VS_SELF_HITS")
multiTargetFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
multiTargetFrame:SetScript("OnEvent", function()
	if event == "PLAYER_REGEN_ENABLED" then
		recentAttackers = {}
		return
	end
	local name = ExtractAttackerName(arg1, " hits you") or ExtractAttackerName(arg1, " crits you")
	RecordAttacker(name)
end)

--------------------------------------------------------------------------------
-- Autoattack attivo (copia della logica in Rotation.lua: eventi nativi dedicati
-- PLAYER_ENTER_COMBAT/PLAYER_LEAVE_COMBAT, indipendenti da chi ha avviato
-- l'attacco).
--------------------------------------------------------------------------------

local autoAttackActive = false

local autoAttackFrame = CreateFrame("Frame", "WRHT_AutoAttackFrame")
autoAttackFrame:RegisterEvent("PLAYER_ENTER_COMBAT")
autoAttackFrame:RegisterEvent("PLAYER_LEAVE_COMBAT")
autoAttackFrame:SetScript("OnEvent", function()
	autoAttackActive = (event == "PLAYER_ENTER_COMBAT")
end)

--------------------------------------------------------------------------------
-- Ultima azione (OPZIONALE): se One Button Rotation e' installato e /wrh
-- startlog e' attivo, WRH_DebugLogDB (SavedVariable di quell'addon) contiene
-- l'ultima azione REALMENTE eseguita - qui solo lettura, mai scrittura.
--------------------------------------------------------------------------------

local function GetLastLoggedAction()
	if type(WRH_DebugLogDB) ~= "table" or type(WRH_DebugLogDB.entries) ~= "table" then
		return nil
	end
	local n = table.getn(WRH_DebugLogDB.entries)
	if n == 0 then
		return nil
	end
	return WRH_DebugLogDB.entries[n]
end

--------------------------------------------------------------------------------
-- Quadratini a schermo.
--------------------------------------------------------------------------------

local squares = {}

-- SetScale(1/UIParent:GetEffectiveScale()) fa in modo che 1 unita' di questo frame corrisponda a
-- 1 pixel fisico dello schermo, indipendentemente dalla UI Scale impostata dal giocatore - senza
-- questo, la dimensione reale dei quadratini in pixel varierebbe con le impostazioni video e il
-- reader esterno (che lavora in pixel fisici) non li troverebbe piu' alla dimensione attesa.
local function CreatePixelFrame()
	local root = CreateFrame("Frame", "WRHT_Root", UIParent)
	root:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 0, 0)
	root:SetWidth(NUM_SQUARES * SQUARE_SIZE)
	root:SetHeight(SQUARE_SIZE)
	root:SetScale(1 / UIParent:GetEffectiveScale())
	root:SetFrameStrata("TOOLTIP") -- resta sopra al resto della UI, cosi' nulla lo ricopre

	for i = 0, NUM_SQUARES - 1 do
		local tex = root:CreateTexture(nil, "OVERLAY")
		tex:SetWidth(SQUARE_SIZE)
		tex:SetHeight(SQUARE_SIZE)
		tex:SetPoint("BOTTOMLEFT", root, "BOTTOMLEFT", i * SQUARE_SIZE, 0)
		tex:SetTexture(0, 0, 0, 1)
		squares[i] = tex
	end

	return root
end

local rootFrame = CreatePixelFrame()

local MAX_PIXEL_VALUE = 16777215 -- 2^24 - 1, il massimo rappresentabile su 3 byte (R,G,B)

-- Scompone value (0-16777215) in byte alto/medio/basso -> R/G/B, come confermato dalla fonte reale
-- della tecnica (vedi commento in testa al file): R e' il byte piu' significativo, B il meno
-- significativo. Aritmetica pura (niente libreria bit, non garantita in Lua 5.0/1.12.1).
local function ValueToColor(value)
	value = value or 0
	if value < 0 then
		value = 0
	elseif value > MAX_PIXEL_VALUE then
		value = MAX_PIXEL_VALUE
	end

	local blue = value - math.floor(value / 256) * 256
	local rest = math.floor(value / 256)
	local green = rest - math.floor(rest / 256) * 256
	local red = math.floor(rest / 256)

	return red / 255, green / 255, blue / 255
end

local function SetSquare(index, value)
	local r, g, b = ValueToColor(value)
	squares[index]:SetTexture(r, g, b, 1)
end

local function ClampPct(v)
	if not v then
		return 0
	end
	if v < 0 then
		return 0
	elseif v > 100 then
		return 100
	end
	return v
end

local heartbeat = 0

-- Raccoglie tutto lo stato corrente in una tabella - usata sia da UpdateSquares (per codificarlo
-- nei pixel) sia da /wrht status (per stamparlo leggibile in chat, senza passare dal reader Python).
local function GatherState()
	local stance = GetCurrentStance()
	local inCombat = UnitAffectingCombat("player")
	local hasTarget = HasAttackableTarget()
	local targetExists = UnitExists("target")

	local playerHpPct = 0
	local playerHpMax = UnitHealthMax("player")
	if playerHpMax and playerHpMax > 0 then
		playerHpPct = math.floor((UnitHealth("player") / playerHpMax) * 100)
	end

	local rage = UnitMana("player") or 0
	if rage > 100 then
		rage = 100
	end

	local targetHpPct = 0
	if targetExists then
		local hpMax = UnitHealthMax("target")
		if hpMax and hpMax > 0 then
			targetHpPct = math.floor((UnitHealth("target") / hpMax) * 100)
		end
	end

	local sunder = targetExists and GetSunderArmorStacks() or 0
	local rend = (targetExists and IsRendAppliedOnTarget()) and 1 or 0
	local demoShout = (targetExists and IsDemoralizingShoutAppliedOnTarget()) and 1 or 0
	local overpowerWindow = IsOverpowerWindowOpen() and 1 or 0
	local revengeWindow = IsRevengeWindowOpen() and 1 or 0

	local attackers = CountRecentAttackers()
	if attackers > 99 then
		attackers = 99
	end

	local autoAttack = autoAttackActive and 1 or 0
	local targetAttackingElse = (targetExists and IsTargetAttackingSomeoneElse()) and 1 or 0
	local knownMask, readyMask = ComputeSpellMasks()

	local lastKind, lastId, lastName = 0, 0, nil
	local lastEntry = GetLastLoggedAction()
	if lastEntry and not lastEntry.noAction then
		lastKind = ACTION_KIND_IDS[lastEntry.actionKind] or 0
		lastName = lastEntry.actionName
		if lastEntry.actionKind == "stance" then
			lastId = STANCE_IDS[lastEntry.actionName] or 0
		else
			lastId = ACTION_IDS[lastEntry.actionName] or 0
		end
	end

	return {
		stance = stance,
		inCombat = inCombat,
		hasTarget = hasTarget,
		playerHpPct = ClampPct(playerHpPct),
		rage = rage,
		targetHpPct = ClampPct(targetHpPct),
		sunder = sunder,
		rend = rend,
		demoShout = demoShout,
		overpowerWindow = overpowerWindow,
		revengeWindow = revengeWindow,
		attackers = attackers,
		autoAttack = autoAttack,
		targetAttackingElse = targetAttackingElse,
		knownMask = knownMask,
		readyMask = readyMask,
		lastKind = lastKind,
		lastId = lastId,
		lastName = lastName,
	}
end

-- Modulo su cui si calcola il checksum (indice 17) - stesso range rappresentabile da un pixel
-- (2^24), cosi' il checksum stesso non deve mai essere troncato da ValueToColor.
local CHECKSUM_MODULO = MAX_PIXEL_VALUE + 1

local function UpdateSquares()
	heartbeat = heartbeat + 1
	if heartbeat > 255 then
		heartbeat = 0
	end

	local s = GatherState()

	-- Valori agli indici 1-19, nello stesso ordine in cui vengono scritti sotto - il checksum
	-- all'indice 20 e' la loro somma modulo CHECKSUM_MODULO. reader/protocol.py deve ricalcolarla
	-- con la stessa formula sugli stessi 19 indici.
	local payload = {
		heartbeat,
		STANCE_IDS[s.stance] or 0,
		s.inCombat and 1 or 0,
		s.hasTarget and 1 or 0,
		s.playerHpPct,
		s.rage,
		s.targetHpPct,
		s.sunder,
		s.rend,
		s.demoShout,
		s.overpowerWindow,
		s.revengeWindow,
		s.attackers,
		s.autoAttack,
		s.lastKind,
		s.lastId,
		s.targetAttackingElse,
		s.knownMask,
		s.readyMask,
	}

	local checksum = 0
	for i = 1, table.getn(payload) do
		checksum = checksum + payload[i]
	end
	checksum = checksum - math.floor(checksum / CHECKSUM_MODULO) * CHECKSUM_MODULO

	SetSquare(0, MAX_PIXEL_VALUE) -- sync marker (bianco puro, R=G=B=255)
	for i = 1, table.getn(payload) do
		SetSquare(i, payload[i])
	end
	SetSquare(20, checksum)
end

local elapsed = 0
rootFrame:SetScript("OnUpdate", function()
	elapsed = elapsed + (arg1 or 0)
	if elapsed < UPDATE_INTERVAL then
		return
	end
	elapsed = 0
	UpdateSquares()
end)

--------------------------------------------------------------------------------
-- Comandi debug, namespace dedicato /wrht.
--------------------------------------------------------------------------------

SLASH_WRHT1 = "/wrht"
SlashCmdList["WRHT"] = function(msg)
	local cmd = string.lower(msg or "")
	local handler = WRHT.commands[cmd]
	if handler then
		handler()
	else
		DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99WRHT:|r sottocomandi: status, calibrate, show, hide")
	end
end

-- Stampa in chat le info necessarie per configurare il reader Python (dimensione/numero quadratini,
-- posizione attesa) - la posizione assoluta sullo schermo dipende dalla finestra del gioco e va
-- misurata dall'utente (vedi README.md, sezione calibrazione).
WRHT.commands["calibrate"] = function()
	DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99WRHT:|r " .. NUM_SQUARES .. " quadratini da " .. SQUARE_SIZE .. "px, ancorati in basso a sinistra dello schermo (BOTTOMLEFT UIParent).")
	DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99WRHT:|r larghezza totale della fila: " .. (NUM_SQUARES * SQUARE_SIZE) .. "px, altezza: " .. SQUARE_SIZE .. "px.")
	DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99WRHT:|r quadratino 0 (sync) deve leggersi bianco puro (255,255,255) - usalo per verificare l'allineamento nel reader.")
end

-- Stampa lo stato corrente in chat, leggibile - utile per verificare in game che la telemetria sia
-- corretta senza dover gia' avere pronto il reader Python (stesso principio di WRH.DescribeContext
-- nel progetto principale).
WRHT.commands["status"] = function()
	local s = GatherState()
	local parts = {}
	table.insert(parts, "stance=" .. tostring(s.stance))
	table.insert(parts, s.inCombat and "in combattimento" or "fuori combattimento")
	table.insert(parts, "rage=" .. s.rage)
	table.insert(parts, "player HP=" .. s.playerHpPct .. "%")
	if s.hasTarget then
		table.insert(parts, "target HP=" .. s.targetHpPct .. "%")
		table.insert(parts, "sunder=" .. s.sunder .. "/5")
		table.insert(parts, "rend=" .. tostring(s.rend == 1))
		table.insert(parts, "demoshout=" .. tostring(s.demoShout == 1))
		table.insert(parts, "target attacca altri=" .. tostring(s.targetAttackingElse == 1))
	else
		table.insert(parts, "nessun target")
	end
	table.insert(parts, "overpower window=" .. tostring(s.overpowerWindow == 1))
	table.insert(parts, "revenge window=" .. tostring(s.revengeWindow == 1))
	table.insert(parts, "attaccanti recenti=" .. s.attackers)
	table.insert(parts, "autoattack=" .. tostring(s.autoAttack == 1))
	table.insert(parts, "knownMask=" .. s.knownMask .. " readyMask=" .. s.readyMask)
	table.insert(parts, "ultima azione (log opzionale)=" .. (s.lastName or "n/d (WRH_DebugLogDB assente o /wrh startlog non attivo)"))

	DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99WRHT:|r " .. table.concat(parts, ", "))
end

WRHT.commands["show"] = function()
	rootFrame:Show()
	DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99WRHT:|r quadratini visibili")
end

WRHT.commands["hide"] = function()
	rootFrame:Hide()
	DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99WRHT:|r quadratini nascosti (nessun dato aggiornato finche' non fai /wrht show)")
end
