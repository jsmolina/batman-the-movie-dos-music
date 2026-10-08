; BATMUS.COM - AdLib/OPL2 music loader for Batman: The Movie (1989, Ocean)
;
;   nasm -f bin -o BATMUS.COM BATMUS.ASM
;   BATMUS                      (runs BATMAN.EXE with music, cleans up on exit)
;
; The game has no FM code at all: it hooks INT 1Ch + INT 9 and leaves INT 8h
; and PIT channel 0 alone. So we own INT 8h at 700 Hz (the WLF tick rate) and
; chain to BIOS every 38.46 ticks, which keeps INT 1Ch at its normal 18.2 Hz.
;
; WLF record = { u8 opl_reg, u8 value, u16 delay_ticks }, 700 Hz.
; Track selection watches INT 21h AH=3Dh/6Ch for the game's own asset loads.

        cpu     8086
        org     0x100

PIT_DIV     equ 1704            ; 1193182/700 = 1704.5
BUFSZ_PARA  equ 6400            ; 102400 bytes, >= MENU.WLF (98,868)
OPL_IDX     equ 0x388
OPL_DAT     equ 0x389
LOCKOUT     equ 36              ; ~2s at 18.2Hz: ignore new triggers after a load
NTRIG       equ 6
TRIGSZ      equ 9

start:  jmp     main

; ============================================================================
;  TRIGGER TABLE  -- edit this if a level picks the wrong track.
;
;  Each row is: length byte, then 8 bytes of pattern. Matched as a substring
;  against every filename the game opens; first match wins, then further
;  triggers are ignored for LOCKOUT ticks.
;
;  'newacid' and 'tower' share one platformer engine in the EXE, and 'bmobile'
;  and 'bwing' share one driving engine, so if two levels come out with the
;  same track just swap those rows -- whichever file the game opens FIRST
;  decides. Keep rows and fname[] in the same order.
; ============================================================================
trig:   db 7,'newacid',0         ; -> AXIS      (level 1, chemical plant)
        db 7,'bmobile',0         ; -> BATMOBIL  (level 2)
        db 5,'bwing',0,0,0       ; -> BATWING   (level 3)
        db 5,'tower',0,0,0       ; -> CATHEDRL  (level 4)
        db 4,'cave',0,0,0,0      ; -> BATCAVE
        db 5,'gmode',0,0,0       ; -> MENU      (EGA/VGA selector)

FNLEN   equ 19
fname:  db 'ADLIB\AXIS.WLF',0,0,0,0,0
        db 'ADLIB\BATMOBIL.WLF',0
        db 'ADLIB\BATWING.WLF',0,0
        db 'ADLIB\CATHEDRL.WLF',0
        db 'ADLIB\BATCAVE.WLF',0,0
        db 'ADLIB\MENU.WLF',0,0,0,0,0

; ---- state -----------------------------------------------------------------
old_i8:     dd 0
old_i21:    dd 0
tick_acc:   dw 0
buf_seg:    dw 0
chunk_seg:  dw 0
nameoff:    dw 0
cur_seg:    dw 0                 ; playback cursor
cur_off:    dw 0
recs_left:  dw 0
total_recs: dw 0
delay_cnt:  dw 0
active:     db 0
cur_trk:    db 0xff
pending:    db 0xff
lockout:    db 0
save_ss:    dw 0
save_sp:    dw 0
path:       times 24 db 0

; ============================================================================
;  INT 8h -- 700 Hz
; ============================================================================
i8:     push    ax
        push    bx
        push    cx
        push    dx
        push    ds
        push    es
        mov     ax, cs
        mov     ds, ax

        cmp     byte [active], 0
        je      .notick
        call    tick
.notick:
        mov     ax, [tick_acc]
        add     ax, PIT_DIV
        mov     [tick_acc], ax
        jc      .bios

        mov     al, 0x20            ; not a BIOS tick: EOI ourselves
        out     0x20, al
        pop     es
        pop     ds
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        iret

.bios:  cmp     byte [lockout], 0
        je      .nolock
        dec     byte [lockout]
.nolock:
        pop     es
        pop     ds
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        jmp     far [cs:old_i8]     ; BIOS does the EOI and the INT 1Ch call

; ---- one music tick; DS=CS --------------------------------------------------
tick:   cmp     word [delay_cnt], 0
        je      .emit
        dec     word [delay_cnt]
        ret

.emit:  cmp     word [recs_left], 0
        jne     .have
        mov     ax, [buf_seg]       ; end of track: loop from the top
        mov     [cur_seg], ax
        mov     word [cur_off], 0
        mov     ax, [total_recs]
        mov     [recs_left], ax
.have:
        mov     es, [cur_seg]
        mov     bx, [cur_off]
        mov     al, [es:bx]         ; OPL register
        mov     ah, [es:bx+1]       ; value
        mov     cx, [es:bx+2]       ; delay in ticks

        add     word [cur_off], 4
        cmp     word [cur_off], 0x8000
        jb      .noseg
        sub     word [cur_off], 0x8000
        add     word [cur_seg], 0x800
.noseg:
        dec     word [recs_left]
        call    opl_w
        jcxz    .emit               ; delay 0 -> same tick, next event
        mov     [delay_cnt], cx
        dec     word [delay_cnt]    ; this tick is spent
        ret

; ---- AL=register AH=value; preserves everything ----------------------------
opl_w:  push    ax
        push    bx
        push    cx
        push    dx
        mov     bx, ax
        mov     dx, OPL_IDX
        mov     al, bl
        out     dx, al
        mov     cx, 6               ; ~3.3us index settle
.w1:    in      al, dx
        loop    .w1
        mov     dx, OPL_DAT
        mov     al, bh
        out     dx, al
        mov     dx, OPL_IDX
        mov     cx, 35              ; ~23us data settle
.w2:    in      al, dx
        loop    .w2
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; ---- key off + full attenuation --------------------------------------------
silence:
        push    ax
        push    bx
        push    cx
        mov     bl, 0xb0            ; key-off all 9 channels
        mov     cx, 9
.ko:    mov     al, bl
        xor     ah, ah
        call    opl_w
        inc     bl
        loop    .ko
        mov     ax, 0x00bd          ; rhythm/AM/VIB off
        call    opl_w
        mov     bl, 0x40            ; total level = max attenuation
        mov     cx, 0x16
.tl:    mov     al, bl
        mov     ah, 0x3f
        call    opl_w
        inc     bl
        loop    .tl
        pop     cx
        pop     bx
        pop     ax
        ret

; ============================================================================
;  INT 21h -- watch AH=3Dh / 6Ch for asset filenames
; ============================================================================
i21:    cmp     ah, 0x3d
        je      .look
        cmp     ah, 0x6c
        je      .look6c
        jmp     far [cs:old_i21]

.look6c:
        push    dx                  ; 6Ch: name is at DS:SI
        mov     dx, si
        call    match
        pop     dx
        jmp     short .chain
.look:  call    match               ; 3Dh: name is at DS:DX

.chain: pushf                       ; let DOS do the open, then regain control
        call    far [cs:old_i21]

        pushf                       ; DOS's result is in AX and the live flags
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    ds
        push    es
        mov     ax, cs
        mov     ds, ax
        cmp     byte [pending], 0xff
        je      .done
        call    load
.done:  pop     es
        pop     ds
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        popf
        retf    2                   ; drop the stale FLAGS image, keep DOS's CF

; ---- substring-match DS:DX against the table, set CS:[pending] -------------
match:  push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di

        cmp     byte [cs:lockout], 0
        jne     .out
        cmp     byte [cs:pending], 0xff
        jne     .out
        mov     [cs:nameoff], dx

        mov     si, trig
        xor     dl, dl                  ; dl = trigger index
.nexttrig:
        cmp     dl, NTRIG
        jae     .out
        mov     bx, [cs:nameoff]        ; restart scan at start of name
.scan:  mov     cl, [cs:si]             ; pattern length
        xor     ch, ch
        mov     di, si
        inc     di                      ; di -> pattern chars
        push    bx
.cmpl:  mov     al, [bx]
        or      al, 0x20                ; fold case
        cmp     al, [cs:di]
        jne     .nomatch
        inc     bx
        inc     di
        loop    .cmpl
        pop     bx                      ; whole pattern matched
        mov     [cs:pending], dl
        jmp     short .out
.nomatch:
        pop     bx
        inc     bx
        cmp     byte [bx], 0            ; end of filename?
        jne     .scan
        add     si, TRIGSZ
        inc     dl
        jmp     .nexttrig
.out:   pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; ---- load CS:[pending] from disk and start it; DS=CS -----------------------
; Safe to use DOS here: the game called INT 21h from normal code and the
; original handler has already returned, so InDOS is back to 0.
load:   mov     bl, [pending]
        mov     byte [pending], 0xff
        cmp     bl, [cur_trk]
        je      .ret
        mov     byte [lockout], LOCKOUT

        cli                             ; stop the ISR touching buffer/state
        mov     byte [active], 0
        sti
        call    silence

        mov     al, bl                  ; path = fname[trk]
        mov     ah, FNLEN
        mul     ah
        mov     si, fname
        add     si, ax
        mov     di, path
        mov     cx, FNLEN
        push    es
        mov     ax, cs
        mov     es, ax
        cld
        rep     movsb
        pop     es

        mov     dx, path
        mov     ax, 0x3d00
        int     0x21
        jc      .ret
        mov     bx, ax                  ; bx = handle

        mov     ax, [buf_seg]           ; read in 32K chunks: DOS can't cross
        mov     [chunk_seg], ax         ; a segment in one transfer
        xor     di, di                  ; di = records loaded
.rd:    push    ds
        mov     ds, [cs:chunk_seg]
        mov     cx, 0x8000
        xor     dx, dx
        mov     ah, 0x3f
        int     0x21
        pop     ds
        jc      .close
        mov     cx, ax                  ; ax = bytes read
        shr     ax, 1
        shr     ax, 1
        add     di, ax                  ; += bytes/4 records
        cmp     cx, 0x8000
        jb      .close                  ; short chunk = EOF
        add     word [chunk_seg], 0x800
        jmp     short .rd

.close: mov     ah, 0x3e
        int     0x21
        cmp     di, 0
        je      .ret

        cli
        mov     ax, [buf_seg]
        mov     [cur_seg], ax
        mov     word [cur_off], 0
        mov     [recs_left], di
        mov     [total_recs], di
        mov     word [delay_cnt], 0
        mov     [cur_trk], bl
        mov     byte [active], 1
        sti
.ret:   ret

; ============================================================================
;  init / run / cleanup
; ============================================================================
main:   mov     sp, 0xfffe

        mov     bx, (file_end - start + 0x100 + 15) >> 4
        mov     ax, cs
        add     ax, bx
        mov     [cs:buf_seg], ax
        add     bx, BUFSZ_PARA
        mov     ah, 0x4a                ; shrink to code + music buffer
        int     0x21
        jnc     .sized
        mov     dx, msg_mem
        jmp     die
.sized:
        mov     ax, 0x3508              ; save old INT 8h / INT 21h
        int     0x21
        mov     [cs:old_i8], bx
        mov     [cs:old_i8+2], es
        mov     ax, 0x3521
        int     0x21
        mov     [cs:old_i21], bx
        mov     [cs:old_i21+2], es

        push    cs                      ; install ours
        pop     ds
        mov     ax, 0x2508
        mov     dx, i8
        int     0x21
        mov     ax, 0x2521
        mov     dx, i21
        int     0x21

        cli                             ; PIT ch0 -> 700 Hz
        mov     al, 0x36
        out     0x43, al
        mov     al, PIT_DIV & 0xff
        out     0x40, al
        mov     al, PIT_DIV >> 8
        out     0x40, al
        sti

        mov     dx, msg_on
        call    say

        mov     [cs:pb_tail+2], cs      ; EXEC BATMAN.EXE
        mov     [cs:pb_f1+2], cs
        mov     [cs:pb_f2+2], cs
        mov     [cs:save_ss], ss
        mov     [cs:save_sp], sp
        push    cs
        push    cs
        pop     ds
        pop     es
        mov     dx, exename
        mov     bx, pb_env
        mov     ax, 0x4b00
        int     0x21
        mov     ss, [cs:save_ss]
        mov     sp, [cs:save_sp]
        push    cs
        pop     ds
        jnc     .ran
        mov     dx, msg_exec
        call    say
.ran:
        cli                             ; PIT back to 18.2 Hz
        mov     al, 0x36
        out     0x43, al
        xor     al, al
        out     0x40, al
        out     0x40, al
        mov     byte [cs:active], 0
        sti
        call    silence

        push    ds                      ; unhook
        lds     dx, [cs:old_i8]
        mov     ax, 0x2508
        int     0x21
        pop     ds
        push    ds
        lds     dx, [cs:old_i21]
        mov     ax, 0x2521
        int     0x21
        pop     ds

        mov     ax, 0x4c00
        int     0x21

die:    call    say
        mov     ax, 0x4c01
        int     0x21

say:    mov     ah, 9
        int     0x21
        ret

exename:  db 'BATMAN.EXE',0
pb_env:   dw 0
pb_tail:  dw tail, 0
pb_f1:    dw dummy_fcb, 0
pb_f2:    dw dummy_fcb, 0
tail:     db 0, 0x0d
dummy_fcb:db 0
          times 11 db ' '
          times 25 db 0

msg_on:   db 'BATMUS: OPL2 at 700Hz, INT 8h hooked. Starting game...',13,10,'$'
msg_mem:  db 'BATMUS: not enough memory for music buffer.',13,10,'$'
msg_exec: db 'BATMUS: could not run BATMAN.EXE.',13,10,'$'

file_end:                       ; music buffer starts on the next paragraph
