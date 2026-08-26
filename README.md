# WRH Telemetry

Estensione companion di [One Button Rotation](../one-button-rotation) (addon Fury Warrior per WoW
1.12.1 su solocraft.org): espone lo stato letto dalla rotazione — stance, rage, HP, stack di Sunder
Armor, ultima azione eseguita, ecc. — come una fila di quadratini colorati disegnati in basso a
sinistra dello schermo di gioco. Un piccolo programma Python li legge via cattura schermo e li
stampa come tabella in console, cosi' puoi mostrarli durante lo streaming (es. con una window/game
capture della console in OBS).

## Cosa NON è

Questo è un canale **di sola visualizzazione**. L'addon legge solo getter già esposti da One Button
Rotation (nessuna chiamata a funzioni con effetti di gioco), e il reader Python **legge soltanto lo
schermo**: non invia mai click, tasti o altri input al gioco, non decide alcuna azione. Non è un bot
e non pilota il personaggio — serve solo a portare informazioni già visibili in game su un secondo
programma per motivi di streaming/telemetria.

## Struttura del repository

```
Addon/WRH_Telemetry/     addon WoW 1.12.1, disegna i quadratini (sola lettura di WRH)
reader/                  script Python che li legge e stampa una tabella in console
```

## Installazione dell'addon

1. Copia la cartella `Addon/WRH_Telemetry` dentro `Interface/AddOns/` del tuo client WoW 1.12.1
   (accanto alla cartella di `One_Button_Rotation`).
2. Avvia il gioco (o `/reload` se già loggato) e assicurati che entrambi gli addon siano attivi
   nella schermata di selezione personaggio.
3. `WRH_Telemetry` funziona anche se `One_Button_Rotation` non è caricato (mostra tutto a zero), ma
   ovviamente per avere dati reali ti serve l'addon principale attivo.
4. Per il campo "ultima azione" ti serve anche il logging di debug dell'addon principale attivo:
   `/wrh startlog` (vedi CLAUDE.md/spec di One Button Rotation) — senza, quel campo resta vuoto.

## Calibrazione (necessaria una volta, o quando cambi risoluzione/posizione finestra)

I quadratini sono ancorati all'angolo in basso a sinistra dello **schermo di gioco** (non
dell'intero monitor, se giochi in finestra). Il reader Python deve sapere dove si trova quell'angolo
in coordinate assolute dello schermo.

1. In game, digita `/wrht calibrate`: stampa in chat dimensione e numero dei quadratini.
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

## Protocollo

17 quadratini da 4x4 pixel fisici ciascuno, in fila da sinistra a destra, un solo canale (R, dato
che l'addon scrive sempre R=G=B in scala di grigi) per valore 0-255. Definito in
`Addon/WRH_Telemetry/WRH_Telemetry.lua` (commento in testa al file) e mirrorato in
`reader/protocol.py` — le due liste vanno mantenute sincronizzate a mano, non c'è generazione
automatica.

| # | Campo | Valori |
|---|-------|--------|
| 0 | sync marker | sempre 255 (bianco), usato dal reader per validare l'allineamento |
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

## Comandi in game

- `/wrht calibrate` — stampa dimensione/posizione attesa dei quadratini
- `/wrht show` / `/wrht hide` — mostra/nasconde i quadratini (nascosti = nessun aggiornamento)

## Limiti noti

- Nessuna verifica in game ancora effettuata su solocraft.org: come da convenzione del progetto
  principale, ogni assunzione (posizione/scala dei quadratini, `UIParent:GetEffectiveScale()`) va
  confermata a schermo prima di fidarsene — usa `/wrht calibrate` + una lettura `--once` del reader
  come primo test.
- Il campo "ultima azione" riflette l'ultimo click reale solo se `/wrh startlog` è attivo
  nell'addon principale; è una scelta deliberata per non duplicare quella logica qui.
- Risoluzioni/scaling non standard (es. scaling del sistema operativo diverso da 100%) possono
  disallineare la cattura pixel-perfect: se il sync marker non si allinea, prova prima a impostare lo
  scaling del sistema al 100% per il display usato da WoW.
