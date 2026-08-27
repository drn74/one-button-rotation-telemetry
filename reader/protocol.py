"""Protocollo di decodifica dei quadratini WRH Telemetry.

DEVE restare sincronizzato a mano con Addon/WRH_Telemetry/WRH_Telemetry.lua (vedi il commento in
cima a quel file per la tabella completa indice -> significato). Nessuna generazione automatica:
se cambi un valore da un lato, cambialo anche qui.
"""

NUM_SQUARES = 17
# 1 pixel fisico per valore - deve combaciare esattamente con SQUARE_SIZE nell'addon Lua. Nessun
# margine di errore sull'allineamento a questa dimensione: vedi la nota nel README sulla precisione
# richiesta di --left/--bottom quando SQUARE_SIZE=1.
SQUARE_SIZE = 1

SYNC = 0
HEARTBEAT = 1
STANCE = 2
IN_COMBAT = 3
HAS_TARGET = 4
PLAYER_HP_PCT = 5
RAGE = 6
TARGET_HP_PCT = 7
SUNDER_STACKS = 8
REND_APPLIED = 9
DEMO_SHOUT_APPLIED = 10
OVERPOWER_WINDOW = 11
REVENGE_WINDOW = 12
RECENT_ATTACKERS = 13
AUTOATTACK_ACTIVE = 14
LAST_ACTION_KIND = 15
LAST_ACTION_ID = 16

SYNC_EXPECTED_VALUE = 255
# Tolleranza sul valore letto per il quadratino di sync: su schermo reale (font hinting del
# gioco, eventuale leggero color management del sistema) raramente si legge un 255 esatto al
# pixel; sotto questa soglia consideriamo comunque l'allineamento valido.
SYNC_TOLERANCE = 10

STANCE_NAMES = {
    0: "nessuna",
    1: "Battle Stance",
    2: "Berserker Stance",
    3: "Defensive Stance",
}

ACTION_KIND_NAMES = {
    0: "nessuna",
    1: "stance",
    2: "spell",
    3: "attack",
}

# Unica tabella per gli id azione: usata sia quando ACTION_KIND e' "spell"/"attack" sia quando e'
# "stance" (gli id 2-4 delle stance in ACTION_IDS combaciano con STANCE_NAMES 1-3, stesso schema
# usato lato Lua in ACTION_IDS/STANCE_IDS).
ACTION_NAMES = {
    0: "nessuna",
    1: "Auto Attack",
    2: "Battle Stance",
    3: "Berserker Stance",
    4: "Defensive Stance",
    5: "Bloodrage",
    6: "Charge",
    7: "Intimidating Shout",
    8: "Execute",
    9: "Overpower",
    10: "Taunt",
    11: "Bloodthirst",
    12: "Whirlwind",
    13: "Shield Slam",
    14: "Revenge",
    15: "Sunder Armor",
    16: "Rend",
    17: "Thunder Clap",
    18: "Heroic Strike",
    19: "Cleave",
    20: "Demoralizing Shout",
}


def decode(values):
    """values: lista di 17 interi 0-255 (uno per quadratino, letti dal canale R). Ritorna un dict
    con i campi decodificati in forma leggibile."""

    def flag(i):
        return values[i] >= 128

    last_kind_id = values[LAST_ACTION_KIND]
    last_action_id = values[LAST_ACTION_ID]
    if last_kind_id == 1:
        last_action_name = STANCE_NAMES.get(last_action_id, "?")
    else:
        last_action_name = ACTION_NAMES.get(last_action_id, "?")

    return {
        "heartbeat": values[HEARTBEAT],
        "stance": STANCE_NAMES.get(values[STANCE], "?"),
        "in_combat": flag(IN_COMBAT),
        "has_target": flag(HAS_TARGET),
        "player_hp_pct": values[PLAYER_HP_PCT],
        "rage": values[RAGE],
        "target_hp_pct": values[TARGET_HP_PCT],
        "sunder_stacks": values[SUNDER_STACKS],
        "rend_applied": flag(REND_APPLIED),
        "demo_shout_applied": flag(DEMO_SHOUT_APPLIED),
        "overpower_window": flag(OVERPOWER_WINDOW),
        "revenge_window": flag(REVENGE_WINDOW),
        "recent_attackers": values[RECENT_ATTACKERS],
        "autoattack_active": flag(AUTOATTACK_ACTIVE),
        "last_action_kind": ACTION_KIND_NAMES.get(last_kind_id, "?"),
        "last_action_name": last_action_name if last_kind_id != 0 else "-",
    }


def is_sync_valid(sync_value):
    return abs(sync_value - SYNC_EXPECTED_VALUE) <= SYNC_TOLERANCE
