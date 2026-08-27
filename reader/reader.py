#!/usr/bin/env python3
"""WRH Telemetry reader.

Legge i quadratini colorati disegnati dall'addon WRH_Telemetry (Addon/WRH_Telemetry) in un angolo
dello schermo di WoW e li mostra come tabella testuale in console, per essere ripresa in uno stream
(es. con una window/game capture della console stessa, o un crop OBS). Sola lettura passiva dello
schermo: non invia mai input al gioco, non clicca, non preme tasti.

Uso tipico:
    python reader.py --left 0 --bottom 1080

--left/--bottom sono le coordinate assolute sullo schermo (stesso sistema usato da un tool come
pyautogui.position() o le impostazioni di OBS) dell'angolo in basso a sinistra della finestra di
gioco, perche' l'addon ancora i quadratini a BOTTOMLEFT dello schermo di gioco (vedi README.md per
la procedura di calibrazione completa e /wrht calibrate in game).
"""

import argparse
import sys
import time

import mss

import protocol


def parse_args():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--left", type=int, help="coordinata X assoluta sullo schermo dell'angolo in basso a sinistra della finestra di gioco")
    p.add_argument("--bottom", type=int, help="coordinata Y assoluta sullo schermo del bordo inferiore della finestra di gioco")
    p.add_argument("--interval", type=float, default=0.2, help="secondi tra una lettura e l'altra (default 0.2, come l'update dell'addon)")
    p.add_argument("--once", action="store_true", help="una sola lettura, stampa e esce (utile per calibrare)")
    p.add_argument("--list-monitors", action="store_true", help="stampa i monitor rilevati da mss (coordinate assolute) ed esce, senza leggere l'addon")
    return p.parse_args()


def read_pixels(sct, region):
    """Ritorna (values, sync_rgb): values e' la lista di 18 interi decodificati (uno per pixel,
    formula R*65536+G*256+B - l'ultimo e' il checksum, non ancora verificato qui), sync_rgb e' la
    tripla (r,g,b) grezza del pixel di sync (indice 0), usata per il controllo di allineamento
    canale per canale."""
    shot = sct.grab(region)
    width = shot.width
    rgb = shot.rgb  # bytes, 3 per pixel (R,G,B), gia' riordinati da mss

    values = []
    sync_rgb = None
    for i in range(protocol.NUM_SQUARES):
        cx = i * protocol.SQUARE_SIZE + protocol.SQUARE_SIZE // 2
        cy = protocol.SQUARE_SIZE // 2
        idx = (cy * width + cx) * 3
        r, g, b = rgb[idx], rgb[idx + 1], rgb[idx + 2]
        if i == protocol.SYNC:
            sync_rgb = (r, g, b)
        values.append(protocol.rgb_to_value(r, g, b))
    return values, sync_rgb


def format_table(decoded, sync_ok, checksum_note=None):
    lines = []
    lines.append("=" * 46)
    if not sync_ok:
        lines.append(" WRH TELEMETRY  [!] non allineato / addon non rilevato")
        lines.append("=" * 46)
        lines.append(" verifica --left/--bottom con /wrht calibrate in game")
        return "\n".join(lines)

    if decoded is None:
        lines.append(" WRH TELEMETRY  in attesa di un frame coerente...")
        lines.append("=" * 46)
        return "\n".join(lines)

    lines.append(" WRH TELEMETRY" + (" " + checksum_note if checksum_note else ""))
    lines.append("=" * 46)
    rows = [
        ("Stance", decoded["stance"]),
        ("In combattimento", "si" if decoded["in_combat"] else "no"),
        ("Target", "si" if decoded["has_target"] else "no"),
        ("HP giocatore", "%d%%" % decoded["player_hp_pct"]),
        ("Rage", str(decoded["rage"])),
        ("HP target", "%d%%" % decoded["target_hp_pct"]),
        ("Sunder Armor", "%d/5" % decoded["sunder_stacks"]),
        ("Rend", "si" if decoded["rend_applied"] else "no"),
        ("Demoralizing Shout", "si" if decoded["demo_shout_applied"] else "no"),
        ("Finestra Overpower", "aperta" if decoded["overpower_window"] else "-"),
        ("Finestra Revenge", "aperta" if decoded["revenge_window"] else "-"),
        ("Attaccanti recenti", str(decoded["recent_attackers"])),
        ("Autoattack", "attivo" if decoded["autoattack_active"] else "fermo"),
        ("Ultima azione", decoded["last_action_name"]),
    ]
    label_width = max(len(r[0]) for r in rows)
    for label, value in rows:
        lines.append(" %s : %s" % (label.ljust(label_width), value))
    lines.append("=" * 46)
    lines.append(" heartbeat=%d" % decoded["heartbeat"])
    return "\n".join(lines)


def clear_screen():
    sys.stdout.write("\x1b[2J\x1b[H")
    sys.stdout.flush()


def main():
    args = parse_args()

    with mss.mss() as sct:
        if args.list_monitors:
            for i, mon in enumerate(sct.monitors):
                print(i, mon)
            return

        if args.left is None or args.bottom is None:
            print("errore: --left e --bottom sono obbligatori (usa --list-monitors per capire le coordinate del tuo schermo, poi vedi README.md per la calibrazione)")
            sys.exit(1)

        region = {
            "left": args.left,
            "top": args.bottom - protocol.SQUARE_SIZE,
            "width": protocol.NUM_SQUARES * protocol.SQUARE_SIZE,
            "height": protocol.SQUARE_SIZE,
        }

        last_decoded = None  # ultimo frame VALIDO (sync ok + checksum ok) mostrato
        last_heartbeat = None
        stale_since = None

        while True:
            values, sync_rgb = read_pixels(sct, region)
            sync_ok = protocol.is_sync_valid(*sync_rgb)
            checksum_note = None

            if sync_ok:
                if protocol.is_checksum_valid(values):
                    last_decoded = protocol.decode(values)
                else:
                    # Frame letto a meta' di un aggiornamento (o corrotto in altro modo): si scarta
                    # e si continua a mostrare l'ultimo frame valido, invece di dati incoerenti.
                    checksum_note = "[!] frame incoerente ignorato, mostro l'ultimo valido"

            clear_screen()
            print(format_table(last_decoded, sync_ok, checksum_note))

            if sync_ok and last_decoded is not None:
                if last_decoded["heartbeat"] == last_heartbeat:
                    if stale_since is None:
                        stale_since = time.time()
                    elif time.time() - stale_since > 3:
                        print(" [!] heartbeat fermo da oltre 3s: /reload, logout o gioco in pausa?")
                else:
                    stale_since = None
                last_heartbeat = last_decoded["heartbeat"]

            if args.once:
                return
            time.sleep(args.interval)


if __name__ == "__main__":
    main()
