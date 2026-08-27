# WRH Telemetry

Addon **indipendente** per WoW 1.12.1 (Fury Warrior, pensato per lo stesso setup di
[One Button Rotation](../one-button-rotation) su solocraft.org, ma non ne richiede il caricamento):
legge da solo stance, rage, HP, stack di Sunder Armor, finestre Overpower/Revenge, ecc. — con le
stesse tecniche già verificate in quel progetto (spellbook scan, parsing del combat log per le
finestre reattive, eventi nativi per l'autoattack) — e li codifica come una fila di quadratini
colorati disegnati in basso a sinistra dello schermo di gioco. Un piccolo programma Python li legge
via cattura schermo e li stampa come tabella in console, cosi' puoi mostrarli durante lo streaming
(es. con una window/game capture della console in OBS).

## Cosa NON è

Questo è un canale **di sola visualizzazione**. L'addon calcola tutto da solo con getter puri
(`UnitHealth`, `GetShapeshiftFormInfo`, `UnitDebuff`, ecc.) e parsing testuale del combat log in
entrata — nessuna chiamata a funzioni con effetti di gioco (mai `CastSpellByName`, `AttackTarget`,
`CastShapeshiftForm`). Il reader Python **legge soltanto lo schermo**: non invia mai click, tasti o
altri input al gioco, non decide alcuna azione. Non è un bot e non pilota il personaggio — serve
solo a portare informazioni già visibili in game su un secondo programma per motivi di
streaming/telemetria.

La codifica RGB (vedi "Protocollo" sotto) prende ispirazione dalla tecnica pixel-to-data usata da
[WowClassicGrindBot](https://github.com/Xian55/WowClassicGrindBot) (un framework di botting, non
affiliato a questo progetto) — qui viene riusata solo la formula di conversione intero↔colore in sé
(un dettaglio di codifica generico, non specifico al botting), per lo stesso scopo di sola
visualizzazione descritto sopra. Nessun codice di automazione di quel progetto è stato copiato.

## Struttura del repository

```
Addon/WRH_Telemetry/     addon WoW 1.12.1, indipendente: legge da solo lo stato e disegna i pixel
reader/protocol.py       decodifica dei pixel in valori (nessuna logica di rotazione)
reader/rotation.py       replica in Python della priority list di Rotation.lua - calcolo puro,
                          nessuna connessione al gioco - per mostrare "cosa consiglierebbe l'addon"
reader/reader.py         cattura schermo, chiama protocol+rotation, stampa la tabella in console
```

## Installazione dell'addon

1. Copia la cartella `Addon/WRH_Telemetry` dentro `Interface/AddOns/` del tuo client WoW 1.12.1.
   Non serve altro: funziona da solo, `One_Button_Rotation` non deve nemmeno essere installato.
2. Avvia il gioco (o `/reload` se già loggato) e assicurati che l'addon sia attivo nella schermata
   di selezione personaggio.
3. **Opzionale** — se hai anche `One_Button_Rotation` installato e attivi il suo logging di debug
   (`/wrh startlog`, vedi CLAUDE.md/spec di quel progetto), il campo "ultima azione" mostra l'ultima
   azione REALMENTE eseguita da quell'addon (letta in sola lettura da `WRH_DebugLogDB`). Senza,
   quel campo resta vuoto — tutto il resto della telemetria (stance, rage, HP, Sunder, ecc.)
   funziona comunque, calcolato autonomamente da questo addon.

## Calibrazione (necessaria una volta, o quando cambi risoluzione/posizione finestra)

I pixel sono ancorati all'angolo in basso a sinistra dello **schermo di gioco** (non dell'intero
monitor, se giochi in finestra). Il reader Python deve sapere dove si trova quell'angolo in
coordinate assolute dello schermo, **con precisione al pixel**: a differenza di una versione con
blocchi più grandi, qui non c'è margine di errore — un `--left`/`--bottom` sbagliato anche di 1px
fa leggere al reader il pixel adiacente (valore completamente diverso), senza nessun errore
visibile a schermo. Imposta anche lo scaling del sistema operativo al 100% sul display usato da
WoW prima di calibrare (vedi "Limiti noti").

1. In game, digita `/wrht calibrate`: stampa in chat dimensione e numero dei pixel.
2. Determina la posizione in pixel assoluti sullo schermo dell'angolo in basso a sinistra della
   finestra di gioco:
   - **Fullscreen** sul monitor principale: quasi sempre `left=0`, `bottom` = altezza del monitor in
     pixel (es. 1080 per un monitor 1920x1080).
   - **Finestra**: usa un qualsiasi tool che mostri la posizione del mouse in coordinate assolute
     dello schermo (su Windows, ad es. l'indicatore di posizione di uno strumento di cattura/misura;
     su Linux, `xdotool getmouselocation`) posizionando il cursore esattamente sull'angolo in basso a
     sinistra della finestra di WoW.
   - Con più monitor, lancia `python reader.py --list-monitors` per vedere i rettangoli (left/top/
     width/height) di ciascun monitor rilevato e orientarti.
3. Lancia il reader con quei valori, ad es.:
   ```
   python reader.py --left 0 --bottom 1080
   ```
4. Se in alto vedi `[!] non allineato / addon non rilevato`, il quadratino 0 (sync, sempre bianco
   puro) non è stato trovato nella posizione attesa — ricontrolla `--left`/`--bottom`, che il gioco
   sia in primo piano (non minimizzato) e che nessun'altra finestra copra quell'angolo.
5. Usa `--once` per una singola lettura rapida durante la calibrazione invece del loop continuo.

## Uso

```
cd reader
pip install -r requirements.txt
python reader.py --left 0 --bottom 1080
```

Il reader ristampa la tabella ogni `--interval` secondi (default 0.2, come l'update dell'addon) e
segnala se lo `heartbeat` smette di avanzare (addon fermo: reload, logout, gioco in pausa/minimizzato).

## Prossima azione consigliata

`reader/rotation.py` reimplementa l'ordine esatto della priority list di `Rotation.lua`
(`GetNextAction`) come **puro calcolo su numeri già ricevuti** — nessuna connessione al gioco, nessun
input simulato, solo testo mostrato in console (riga `>> PROSSIMA AZIONE: ...`). L'addon calcola due
bitmask (pixel 18-19, `known_mask`/`ready_mask`) leggendo cooldown e costo in rage di ogni abilità
dal tooltip (stessa tecnica di sola lettura di `Rotation.lua`, `IsSpellCastableNow`) — il reader le
usa per sapere quali abilità sono conosciute/castabili ORA, senza doverle interrogare da solo.

La fedeltà rispetto all'originale è completa: stessa sequenza di priorità, comprese le sottigliezze
(es. la scelta Cleave/Heroic Strike è fatta una volta sola come nell'originale, senza fallback
all'altra se quella scelta non è castabile). L'unica assunzione: la funzione valuta sempre "cosa
faresti restando nella stance attuale" — non predice mai uno switch di stance, perché nell'addon
originale quella scelta spetta al giocatore (quale macro premere), non alla priority list.

Va tenuto sincronizzato a mano con `Rotation.lua` nel repo
[one-button-rotation](../one-button-rotation): se la priority list cambia lì, va aggiornata anche
qui.

## Protocollo

21 pixel fisici in fila da sinistra a destra (1 pixel = 1 valore, riga alta 1px, larga 21px in
totale — quasi invisibile). Nessun margine di errore sull'allineamento a questa dimensione: vedi
"Calibrazione" sotto.

**Tre livelli di controllo separati**, nessuno copre da solo la validità di un frame:
- **pixel 0 (sync)** verifica l'*allineamento* — il reader sta puntando al punto giusto?
- **pixel 20 (checksum)** verifica la *coerenza* — questo frame specifico è internamente
  consistente, o è stato catturato a metà di un aggiornamento (raro, dato che WoW disegna un intero
  frame in un colpo solo, ma non impossibile)? È la somma dei valori agli indici 1-19 modulo
  16.777.216; il reader la ricalcola dai pixel letti e, se non torna, scarta quel frame e continua a
  mostrare l'ultimo valido invece di dati incoerenti.
- il **pixel 1 (heartbeat)** resta il terzo controllo, per la *vivacità* — l'addon sta ancora
  aggiornando, o è fermo (reload/logout/pausa)?

Ogni pixel porta un intero **0-16.777.215** (24 bit) spalmato sui tre canali: `valore = R*65536 +
G*256 + B` (R = byte più significativo, G = medio, B = meno significativo). Ordine verificato sulla
fonte reale della tecnica ([Xian55/WowClassicGrindBot](https://github.com/Xian55/WowClassicGrindBot),
`Addons/DataToColor/DataToColor.lua`, funzione `int()`) — R porta il byte alto, non il basso. Tutti
i campi attuali stanno comunque entro 0-255 (percentuali, flag, contatori piccoli), quindi R e G
restano quasi sempre a 0 e solo B varia: il redesign segue la tecnica corretta e lascia margine per
valori più grandi in futuro (es. HP/rage assoluti invece di percentuali), non risponde a una
necessità immediata. Definito in `Addon/WRH_Telemetry/WRH_Telemetry.lua` (commento in testa al
file, funzione `ValueToColor`) e mirrorato in `reader/protocol.py` (`rgb_to_value`) — le due liste
vanno mantenute sincronizzate a mano, non c'è generazione automatica.

| # | Campo | Valori |
|---|-------|--------|
| 0 | sync marker | sempre 16.777.215 (R=G=B=255, bianco), usato dal reader per validare l'allineamento |
| 1 | heartbeat | contatore 0-255 che avanza a ogni update, indica dati "vivi" |
| 2 | stance | 0=nessuna, 1=Battle, 2=Berserker, 3=Defensive |
| 3 | in combattimento | 0/1 |
| 4 | ha target attaccabile | 0/1 |
| 5 | HP giocatore % | 0-100 |
| 6 | rage | 0-100 |
| 7 | HP target % | 0-100 (0 se nessun target) |
| 8 | stack Sunder Armor | 0-5 |
| 9 | Rend applicato | 0/1 |
| 10 | Demoralizing Shout applicato | 0/1 |
| 11 | finestra Overpower aperta | 0/1 |
| 12 | finestra Revenge aperta | 0/1 |
| 13 | attaccanti recenti (euristica multi-target) | 0-99 |
| 14 | autoattack attivo | 0/1 |
| 15 | kind ultima azione loggata | 0=nessuna, 1=stance, 2=spell, 3=attack |
| 16 | id ultima azione loggata | vedi `ACTION_NAMES`/`STANCE_NAMES` in `reader/protocol.py` |
| 17 | target sta attaccando qualcun altro (per Taunt) | 0/1 |
| 18 | known_mask | bitmask spell conosciute, 1 bit per abilità (bit per id N = 2^(N-1), vedi `ACTION_IDS`) |
| 19 | ready_mask | bitmask spell castabili ORA (cooldown pronto + rage sufficiente), stessi bit di known_mask |
| 20 | checksum | somma degli indici 1-19 modulo 16.777.216 — vedi sopra |

## Comandi in game

- `/wrht status` — stampa in chat lo stato corrente in forma leggibile (utile per verificare che la
  telemetria sia corretta senza dover ancora avere pronto il reader Python)
- `/wrht calibrate` — stampa dimensione/posizione attesa dei quadratini
- `/wrht show` / `/wrht hide` — mostra/nasconde i quadratini (nascosti = nessun aggiornamento)

## Limiti noti

- Nessuna verifica in game ancora effettuata su solocraft.org: come da convenzione del progetto
  principale, ogni assunzione (posizione/scala dei quadratini, `UIParent:GetEffectiveScale()`,
  testo esatto dei messaggi di combat log per Overpower/Revenge/multi-target) va confermata a
  schermo prima di fidarsene — usa `/wrht status` come primo test (non richiede il reader Python),
  poi `/wrht calibrate` + una lettura `--once` del reader per il canale pixel.
- Il campo "ultima azione (log opzionale)" riflette l'ultimo click reale solo se
  `One_Button_Rotation` è installato E il suo `/wrh startlog` è attivo — indipendente dalla riga
  "PROSSIMA AZIONE" (quella è sempre calcolata, non richiede l'altro addon).
- "PROSSIMA AZIONE" dipende da `known_mask`/`ready_mask` (pixel 18-19), calcolate in Lua con lo
  stesso scan tooltip di `Rotation.lua` (`GetSpellCooldown` + parsing `"(%d+) Rage"`) — mai
  verificato in game per QUESTO addon (solo per l'originale, in un contesto diverso): va confermato
  con `/wrht status` (mostra `knownMask`/`readyMask` come numeri) prima di fidarsene per lo stream.
- Risoluzioni/scaling non standard (es. scaling del sistema operativo diverso da 100%) possono
  disallineare la cattura pixel-perfect: se il sync marker non si allinea, prova prima a impostare lo
  scaling del sistema al 100% per il display usato da WoW.
