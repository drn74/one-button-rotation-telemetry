"""Replica in Python della priority list di Rotation.lua (GetNextAction) di One Button Rotation.

IMPORTANTE: questo modulo non esegue MAI nulla in game - non c'e' nessuna connessione dal reader
Python al client WoW se non la lettura passiva dello schermo gia' fatta in reader.py. Le funzioni
qui dentro sono pure: prendono lo stato gia' decodificato (protocol.decode()) e calcolano quale
sarebbe la prossima azione secondo la stessa logica dell'addon originale, solo per mostrarla come
testo in console durante lo streaming ("cosa consiglierebbe l'addon ORA").

DEVE restare sincronizzato a mano con l'ordine delle priorita' in Rotation.lua (GetNextAction) del
repo one-button-rotation - se quella funzione cambia, questa va aggiornata di conseguenza. Assume
sempre che la stance attuale sia gia' quella "giusta" per la macro che verrebbe premuta (l'addon
originale, se non lo fosse, si limiterebbe a switchare stance in un click separato - qui non hai
un click da simulare, quindi questa funzione valuta solo "cosa faresti restando nella stance
attuale", che e' l'informazione utile per uno spettatore in streaming).

Le uniche informazioni che l'addon originale userebbe e che QUI non sono disponibili sono i
cooldown/rage cost delle spell non coperte da known_mask/ready_mask (nessuna: tutte le abilita'
della priority list sono coperte) - la fedelta' rispetto a Rotation.lua e' quindi completa, a patto
che known_mask/ready_mask siano aggiornati (dipendono dall'addon Lua, non da questo modulo).
"""

import protocol

BLOODRAGE_LOW_RAGE_THRESHOLD = 20
PANIC_HP_THRESHOLD = 30
EXECUTE_HP_THRESHOLD = 20
RAGE_DUMP_THRESHOLD = 60
MULTI_TARGET_THRESHOLD = 2


def _is_known(name, state):
    bit = 1 << (protocol.ACTION_IDS[name] - 1)
    return (state["known_mask"] & bit) != 0


def _is_ready(name, state):
    bit = 1 << (protocol.ACTION_IDS[name] - 1)
    return (state["ready_mask"] & bit) != 0


def _should_bloodrage(state):
    # Equivalente a ShouldBloodrage() in Rotation.lua: IsBloodrageWorthwhile() (rage bassa) E
    # castabile ora (ready_mask gia' include il check di rage cost/cooldown).
    return state["rage"] < BLOODRAGE_LOW_RAGE_THRESHOLD and _is_ready("Bloodrage", state)


def _action(kind, name):
    return {"kind": kind, "name": name}


def get_next_action(state):
    """state: dict ritornato da protocol.decode(). Ritorna {"kind","name"} o None (nessuna azione
    disponibile ora), stesso formato di WRH.GetNextAction() in Rotation.lua."""

    mode = state["stance"]
    if mode not in ("Battle Stance", "Berserker Stance", "Defensive Stance"):
        # Nessuna stance attiva (es. appena creato il personaggio): l'addon originale non
        # potrebbe valutare nessuna macro finche' non sei in una stance.
        return None

    has_target = state["has_target"]
    in_combat = state["in_combat"]

    # 0: priorita' assoluta - autoattack (stessa posizione di GetNextAction).
    if has_target and not state["autoattack_active"]:
        return _action("attack", "Auto Attack")

    # 2: apertura fuori combattimento.
    if not in_combat and has_target:
        if _should_bloodrage(state):
            return _action("spell", "Bloodrage")
        if mode == "Battle Stance" and _is_ready("Charge", state):
            return _action("spell", "Charge")
        return None

    if not has_target:
        return None

    # 0: emergenza - HP giocatore sotto soglia critica (solo Battle, come nell'originale).
    if in_combat and mode == "Battle Stance" and state["player_hp_pct"] < PANIC_HP_THRESHOLD:
        if _is_ready("Intimidating Shout", state):
            return _action("spell", "Intimidating Shout")

    # 3: Execute sotto il 20% HP del target.
    if state["target_hp_pct"] < EXECUTE_HP_THRESHOLD and _is_ready("Execute", state):
        return _action("spell", "Execute")

    # Overpower (solo Battle): finestra di 4s dopo una schivata nemica.
    if mode == "Battle Stance" and state["overpower_window"] and _is_ready("Overpower", state):
        return _action("spell", "Overpower")

    # Taunt (solo Defensive/Tank): il target sta attaccando qualcun altro.
    if mode == "Defensive Stance" and state["target_attacking_someone_else"] and _is_ready("Taunt", state):
        return _action("spell", "Taunt")

    # Bloodrage in combattimento (nessun vincolo di stance).
    if _should_bloodrage(state):
        return _action("spell", "Bloodrage")

    # Universale Battle/Berserker, mai Defensive (talento Fury).
    if mode in ("Battle Stance", "Berserker Stance") and _is_ready("Bloodthirst", state):
        return _action("spell", "Bloodthirst")

    if mode == "Berserker Stance" and _is_ready("Whirlwind", state):
        return _action("spell", "Whirlwind")

    if mode == "Defensive Stance":
        if _is_ready("Shield Slam", state):
            return _action("spell", "Shield Slam")
        if state["revenge_window"] and _is_ready("Revenge", state):
            return _action("spell", "Revenge")

    # Sunder Armor, prima passata (fino a 2 stack).
    if state["sunder_stacks"] < 2 and _is_ready("Sunder Armor", state):
        return _action("spell", "Sunder Armor")

    if mode in ("Battle Stance", "Defensive Stance") and not state["rend_applied"] and _is_ready("Rend", state):
        return _action("spell", "Rend")

    # Sunder Armor, seconda passata (fino a 5 stack).
    if state["sunder_stacks"] < 5 and _is_ready("Sunder Armor", state):
        return _action("spell", "Sunder Armor")

    if mode in ("Battle Stance", "Defensive Stance") and _is_ready("Thunder Clap", state):
        return _action("spell", "Thunder Clap")

    # Rage-dump finale: la scelta del NOME e' fatta una volta sola, come nell'originale - Cleave
    # solo se conosciuta E 2+ nemici rilevati, altrimenti sempre Heroic Strike (nessun fallback
    # all'altra se quella scelta non risulta castabile: stesso comportamento di
    # Rotation.lua/GetNextAction, dove l'entry della rage-dump ha un solo nome candidato).
    if state["rage"] > RAGE_DUMP_THRESHOLD:
        cleave_chosen = _is_known("Cleave", state) and state["recent_attackers"] >= MULTI_TARGET_THRESHOLD
        dump_name = "Cleave" if cleave_chosen else "Heroic Strike"
        if _is_ready(dump_name, state):
            return _action("spell", dump_name)

    if not state["demo_shout_applied"] and _is_ready("Demoralizing Shout", state):
        return _action("spell", "Demoralizing Shout")

    return None
