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

# Ogni pixel porta un intero 0-16777215 (24 bit) spalmato su R (byte alto), G (byte medio),
# B (byte basso) - value = R*65536 + G*256 + B. Ordine confermato sulla fonte reale della tecnica
# (Xian55/WowClassicGrindBot, Addons/DataToColor/DataToColor.lua, funzione int()): R e' il byte piu'
# significativo, non il meno significativo - vedi il commento in testa a WRH_Telemetry.lua.
MAX_PIXEL_VALUE = 16777215


def rgb_to_value(r, g, b):
    return (r << 16) | (g << 8) | b


CHANNEL_EXPECTED_VALUE = 255
# Tolleranza per canale sul pixel di sync (atteso R=G=B=255): su schermo reale (font hinting del
# gioco, eventuale leggero color management del sistema) raramente si legge un 255 esatto al
# pixel; sotto questa soglia per OGNI canale consideriamo comunque l'allineamento valido. Controllo
# per canale (non sul valore intero composito) perche' un errore di pochi livelli sul byte alto
# sposterebbe il valore composito di decine di migliaia, mentre lo stesso errore sul byte basso e'
# quasi ininfluente - un'unica soglia sull'intero sarebbe inconsistente tra i tre canali.
CHANNEL_TOLERANCE = 10

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
    """values: lista di 17 interi 0-16777215, uno per pixel, gia' decodificati da (R,G,B) con
    rgb_to_value(). Ritorna un dict con i campi decodificati in forma leggibile. Tutti i campi
    attuali stanno entro 0-255 (percentuali, flag, contatori piccoli), quindi la logica sotto
    tratta i valori decodificati come se fossero ancora byte singoli - resta comunque corretta
    anche se in futuro un campo dovesse usare il range piu' ampio."""

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


def is_sync_valid(r, g, b):
    return (
        abs(r - CHANNEL_EXPECTED_VALUE) <= CHANNEL_TOLERANCE
        and abs(g - CHANNEL_EXPECTED_VALUE) <= CHANNEL_TOLERANCE
        and abs(b - CHANNEL_EXPECTED_VALUE) <= CHANNEL_TOLERANCE
    )
