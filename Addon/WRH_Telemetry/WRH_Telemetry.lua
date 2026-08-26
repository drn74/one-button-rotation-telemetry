-- WRH Telemetry: legge lo stato gia' esposto (sola lettura) dall'addon One Button Rotation (WRH)
-- e lo codifica in una fila di quadratini colorati ancorati in basso a sinistra dello schermo, cosi'
-- un programma esterno (screen-capture) puo' leggerlo e mostrarlo in una tabella durante lo
-- streaming. Addon separato e indipendente: non modifica ne' dipende dal caricamento di
-- One_Button_Rotation (OptionalDeps nel .toc), degrada in sicurezza (tutto a zero) se non presente.
--
-- Nessuna azione di gioco: non chiama mai WRH.GetNextAction() (ha un side-effect reale, avvia
-- l'autoattack) ne' CastSpellByName/AttackTarget/CastShapeshiftForm. Legge solo getter puri gia'
-- esposti da Rotation.lua/StanceCheck.lua, piu' l'ultima entry di WRH_DebugLogDB (SavedVariables di
-- DebugLog.lua, gia' scritta dai click reali dell'utente) per il campo "ultima azione" - per questo
-- quel campo resta a 0/nessuna finche' l'utente non attiva /wrh startlog nell'addon principale.
--
-- Protocollo (vedi anche README.md nel repo, e reader/protocol.py sul lato Python - le due liste
-- DEVONO restare sincronizzate a mano, non c'e' generazione automatica):
-- indice 0  sync marker, sempre 255 - il reader lo usa per verificare l'allineamento del capture
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
-- indice 15 kind ultima azione loggata: 0=nessuna, 1=stance, 2=spell, 3=attack
-- indice 16 id ultima azione loggata (vedi ACTION_IDS/STANCE_IDS sotto)

WRHT = {}

local NUM_SQUARES = 17
local SQUARE_SIZE = 4 -- pixel fisici per lato di ogni quadratino
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

local function SetSquare(index, value)
	value = value or 0
	if value < 0 then
		value = 0
	elseif value > 255 then
		value = 255
	end
	local c = value / 255
	squares[index]:SetTexture(c, c, c, 1)
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

-- Ultima entry di WRH_DebugLogDB (One_Button_Rotation, DebugLog.lua) - gia' scritta dai click reali
-- dell'utente quando /wrh startlog e' attivo. Nessuna chiamata a funzioni con side-effect qui: solo
-- lettura di una SavedVariable.
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

local heartbeat = 0

local function UpdateSquares()
	SetSquare(0, 255) -- sync marker

	if type(WRH) ~= "table" or type(WRH.GetCurrentStance) ~= "function" then
		-- One Button Rotation non (ancora) caricato: tutto a zero tranne il sync marker.
		for i = 1, NUM_SQUARES - 1 do
			SetSquare(i, 0)
		end
		return
	end

	heartbeat = heartbeat + 1
	if heartbeat > 255 then
		heartbeat = 0
	end

	local stance = WRH.GetCurrentStance()
	local inCombat = UnitAffectingCombat("player")
	local hasTarget = (WRH.HasAttackableTarget and WRH.HasAttackableTarget()) or UnitExists("target")
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

	local sunder = (targetExists and WRH.GetSunderArmorStacks) and WRH.GetSunderArmorStacks() or 0
	local rend = (targetExists and WRH.IsRendAppliedOnTarget and WRH.IsRendAppliedOnTarget()) and 1 or 0
	local demoShout = (targetExists and WRH.IsDemoralizingShoutAppliedOnTarget and WRH.IsDemoralizingShoutAppliedOnTarget()) and 1 or 0
	local overpowerWindow = (WRH.IsOverpowerWindowOpen and WRH.IsOverpowerWindowOpen()) and 1 or 0
	local revengeWindow = (WRH.IsRevengeWindowOpen and WRH.IsRevengeWindowOpen()) and 1 or 0

	local attackers = (WRH.CountRecentAttackers and WRH.CountRecentAttackers()) or 0
	if attackers > 99 then
		attackers = 99
	end

	local autoAttack = (WRH.IsAutoAttackActive and WRH.IsAutoAttackActive()) and 1 or 0

	local lastKind, lastId = 0, 0
	local lastEntry = GetLastLoggedAction()
	if lastEntry and not lastEntry.noAction then
		lastKind = ACTION_KIND_IDS[lastEntry.actionKind] or 0
		if lastEntry.actionKind == "stance" then
			lastId = STANCE_IDS[lastEntry.actionName] or 0
		else
			lastId = ACTION_IDS[lastEntry.actionName] or 0
		end
	end

	SetSquare(1, heartbeat)
	SetSquare(2, STANCE_IDS[stance] or 0)
	SetSquare(3, inCombat and 1 or 0)
	SetSquare(4, hasTarget and 1 or 0)
	SetSquare(5, ClampPct(playerHpPct))
	SetSquare(6, rage)
	SetSquare(7, ClampPct(targetHpPct))
	SetSquare(8, sunder)
	SetSquare(9, rend)
	SetSquare(10, demoShout)
	SetSquare(11, overpowerWindow)
	SetSquare(12, revengeWindow)
	SetSquare(13, attackers)
	SetSquare(14, autoAttack)
	SetSquare(15, lastKind)
	SetSquare(16, lastId)
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

-- Comandi debug, namespace dedicato /wrht (distinto da /wrh di One Button Rotation).
WRHT.commands = {}

SLASH_WRHT1 = "/wrht"
SlashCmdList["WRHT"] = function(msg)
	local cmd = string.lower(msg or "")
	local handler = WRHT.commands[cmd]
	if handler then
		handler()
	else
		DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99WRHT:|r sottocomandi: calibrate, show, hide")
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

WRHT.commands["show"] = function()
	rootFrame:Show()
	DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99WRHT:|r quadratini visibili")
end

WRHT.commands["hide"] = function()
	rootFrame:Hide()
	DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99WRHT:|r quadratini nascosti (nessun dato aggiornato finche' non fai /wrht show)")
end
