# BATMUS

Adds AdLib/OPL2 music to Batman: The Movie (1989, Ocean). The game ships an
`ADLIB/` folder of music but `BATMAN.EXE` contains no FM playback code.

## Executing
Run `BATMUS` instead of `BATMAN`. It hooks, EXECs the game, and restores the
timer and interrupt vectors on exit.

## Build

    nasm -f bin -o BATMUS.COM BATMUS.ASM



## How it works

The executable hooks INT 1Ch (installer at image offset 0x08) and INT 9 (ISR at
0x5fa), and never touches INT 8h or PIT channel 0. The `out 43h/42h/61h` at
0xf8e6 is PC speaker only. The original game was very limited in music.

That leaves INT 8h free. BATMUS reprograms PIT channel 0 to 700 Hz (divisor
1704) and plays one WLF tick per interrupt. It chains to the original INT 8h
whenever a `+= 1704` accumulator overflows 16 bits — 65536/1704 = 38.46 ticks,
or 18.207 Hz — so BIOS keeps the clock and fires INT 1Ch at the rate the game
expects. Ticks that do not chain issue their own EOI to port 20h.

Track selection hooks INT 21h AH=3Dh/6Ch and substring-matches the filenames the
game opens against a table. The WLF load happens after the original handler
returns, where InDOS is back to 0 and DOS calls are safe.

## WLF format

Four bytes per record: `u8 opl_register, u8 value, u16 delay_ticks`, at 700 Hz.
Tracks loop from the start; the preamble is an OPL2 reset (reg 01 = 20 for wave
select enable, reg 04 = 60 then 80).


## Trigger table

Levels are identified by the asset files they open, not by a level variable.
The table at the top of `BATMUS.ASM` maps a filename substring to a track:

    newacid -> AXIS        bwing -> BATWING     cave  -> BATCAVE
    bmobile -> BATMOBIL    tower -> CATHEDRL    gmode -> MENU

First match wins, then further triggers are ignored for about two seconds.

`newacid` and `tower` share one platformer engine in the executable, and
`bmobile` and `bwing` share one driving engine. If a level load opens both files
of a pair the trigger is ambiguous and the wrong track plays — swap those two
rows in the table to fix it. This is the only part expected to need tuning.

## Memory

Loader is 1226 bytes plus a 100 KB track buffer (MENU.WLF is the largest at
96 KB), shrunk to 101.5 KB with INT 21h AH=4Ah before EXEC. The game needs
149 KB minimum and has maxalloc 0xFFFF, so it takes everything left.

Credits to spark for the adlib music.
