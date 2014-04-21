;**********************************************************************
;* MODULE NAME :  hrtimer.asm            AUTHOR:  Rick Fishman        *
;* DATE WRITTEN:  11-23-91                                            *
;*                                                                    *
;* DESCRIPTION:                                                       *
;*                                                                    *
;*  This device driver provides a high-resolution timer for OS/2      *
;*                                                                    *
;*  The source code was obtained from the Fall 1991 issue of IBM      *
;*  Personal Systems Developer magazine.                              *
;*                                                                    *
;*  modified 2/99 by Heinz Repp to improve accuracy, minimize         *
;*  interrupt time = system load, use 386 instructions under          *
;*  OS/2 v2.1 and up, plus a second simplified read interface         *
;*                                                                    *
;**********************************************************************

        .MODEL SMALL
        .386

;*********************************************************************
;*----------------------------- EQUATES -----------------------------*
;*********************************************************************

RP_StatusError          equ     8000h   ; RP_Status error bit
RP_StatusDone           equ     0100h   ; RP_Status done bit
RP_StatusUnknown        equ     0003h   ; unknown command
RP_StatusGenFail        equ     000Ch   ; general failure

                                        ; DEVICE HELPER FUNCTIONS
DevHlp_PhysToVirt       equ     15h     ; Convert a physical address to virtual
DevHlp_SetTimer         equ     1Dh     ; Hook into the Motorola timer int

i8253CountRegister      equ     40h     ; 8253 Counter Register
i8253CtrlByteRegister   equ     43h     ; 8253 Control Byte Register
i8253CmdReadCtrZero     equ     0       ; Latch Command

NanosInATickNum         equ   17600     ; Number of nanoseconds in 1 8253 tick
NanosInATickDen         equ      21     ;   as a ratio: 6 significant digits!
                                        ;   (before we had only 2: 840)

HRTimerVersion          equ     1       ; major release version
HRTimerRevision         equ     1       ; minor release version

cr                      equ     0dh     ; ASCII code for carraige return
lf                      equ     0ah     ; ASCII code for line feed

stdout                  equ     1       ; File handle for standard output

;**********************************************************************
;*------------------------------ MACROS ------------------------------*
;**********************************************************************

Read8253IntoAx  MACRO                      ; Put 8253 counter 0 value in ax

        mov     al, i8253CmdReadCtrZero    ; Request Counter Latch
        out     i8253CtrlByteRegister, al
        in      al, i8253CountRegister     ; Get LSB and save it
        mov     ah, al
        in      al, i8253CountRegister     ; Get MSB and save it
        xchg    ah, al

                ENDM

;**********************************************************************
;*---------------------------- STRUCTURES ----------------------------*
;**********************************************************************

ReadData                struc           ; Data passed to caller of DosRead

    RD_Millisecs        dd      ?       ; Current millisecond count
    RD_Nanosecs         dd      ?       ; Current nanosecond count
    RD_Version          dw      ?       ; HRTIMER.SYS version - hi
    RD_Revision         dw      ?       ; HRTIMER.SYS version - lo

ReadData                ends

ReadDataLen             equ     TYPE ReadData ; Length of ReadData


RequestPacket           struc           ; Request Packet header

    RP_Length           db      ?       ; Request Packet length
                        db      ?       ; Block devices only
    RP_CommandCode      db      ?       ; Command
    RP_Status           dw      ?       ; Command Status Code
                        dd      ?       ; Reserved
                        dd      ?       ; Queue Linkage - not used here

RequestPacket           ends


RequestPktInit          struc           ; Initialization Request Packet

                        db    13 dup(?) ; Request Packet Header
    RPI_NumberUnits     db      ?       ; Block devices only - used to cancel
                                        ; DevHlp pointer in, on return from init
    RPI_CodeSegLen      dw      ?       ;     Code segment length
    RPI_DataSegLen      dw      ?       ;     Data segment length
    RPI_CommandLine     dd      ?       ; Pointer to command line
                        db      ?       ; Block devices only

RequestPktInit          ends


RequestPktRead          struc           ; Read Request Packet (from DosRead)

                        db    13 dup(?) ; Request Packet header
                        db      ?       ; Block devices only
    RPR_TransferAddr    dd      ?       ; Physical address of read buffer
    RPR_BytesRequested  dw      ?       ; Number of bytes to read

RequestPktRead          ends

;**********************************************************************
;*----------------------------- EXTERNS ------------------------------*
;**********************************************************************

        extrn  DosWrite:far

;**********************************************************************
;*-------------------------- DATA SEGMENT ----------------------------*
;**********************************************************************

DGROUP          group   _DATA

_DATA           SEGMENT word public  'DATA'

;**********************************************************************
;*---------------------- Device Driver Header ------------------------*
;**********************************************************************

TimerHeader             label   byte            ; Device Driver header

    NextDeviceDriver    dd      -1              ; Last driver in chain
    DeviceAttribute     dw      1000100010000000B  ; Char,Open/Close,Level 1
    StrategyOffset      dw      offset Strategy ; Offset of Strategy Routine
                        dw      -1              ; IDC - not used here
    DeviceName          db      'TIMER$  '      ; Driver Device-Name
                        db      8 dup(0)        ; Reserved

;**********************************************************************
;*------------ Data areas used by Strategy and Interrupt -------------*
;**********************************************************************

DevHlpPtr               dd      ?               ; Pointer to Device Helper
                                                ;   routine - Set at init rqst
UserCount               dw      0               ; Number of active users

Last8253                dw      ?               ; value last read from timer

Left8253                dd      ?               ; counter for 8253 underruns

BytesWritten            dw      ?               ; Used for DosWrite calls

;**********************************************************************
;*--------------------- Command (Request) List -----------------------*
;**********************************************************************

CmdList         label   word

                dw      Initialize      ;  0 = Initialize driver
                dw      Error           ;  1 = Media Check
                dw      Error           ;  2 = Build BPB
                dw      Error           ;  3 = Not used
                dw      Read            ;  4 = Read from device
                dw      DummyRet        ;  5 = Non-destructive read
                dw      DummyRet        ;  6 = Return input status
                dw      DummyRet        ;  7 = Flush input buffers
                dw      DummyRet        ;  8 = Write to device
                dw      DummyRet        ;  9 = Write with verify
                dw      DummyRet        ; 10 = Return output status
                dw      DummyRet        ; 11 = Flush output buffers
                dw      Error           ; 12 = Not used
                dw      Open            ; 13 = Device open
                dw      Close           ; 14 = Device close

MaxCmd          equ     ( $ - CmdList ) / TYPE CmdList - 1
                                        ; highest command is # - 1!

CopyRightMsg    db      cr, lf
                db      'High Resolution Timer - Version 1.1', cr, lf
                db      'Courtesy of Code Blazers, Inc. 1991', cr, lf
                db      'Revised Version / 2nd API 2/99 by Heinz Repp'
                db      cr, lf, lf
CopyRightMsgLen equ     $ - CopyRightMsg

InitNotOkMsg    db      'HRTIMER.SYS Initialization Failed', cr, lf
InitNotOkMsgLen equ     $ - InitNotOkMsg

_DATA           ENDS

;**********************************************************************
;*-------------------------- CODE SEGMENT ----------------------------*
;**********************************************************************

_TEXT           SEGMENT word public  'CODE'

                assume cs:_TEXT, ds:DGROUP

;**********************************************************************
;*---------------------------- Strategy ------------------------------*
;*                                                                    *
;*  STRATEGY ENTRY POINT.                                             *
;*                                                                    *
;*  INPUT: ES:BX = address of request packet                          *
;*                                                                    *
;*  OUTPUT: nothing                                                   *
;*                                                                    *
;*--------------------------------------------------------------------*
;**********************************************************************

Strategy        PROC    far

        cmp     es:[bx].RP_CommandCode, MaxCmd  ; Command within jumb table?
        jbe     short JumpCmd                   ;   YES: execute command routine

        call    Error                           ;   NO: send back error
        jmp     short exit                      ;       and exit

JumpCmd:

        mov     al, es:[bx].RP_CommandCode      ; Isolate command,
        cbw                                     ;   convert to word,
        mov     si, ax                          ;   put into index register,
        shl     si, 1                           ;   multiply by 2 so it is a
                                                ;   word rather than byte offset
        call    CmdList [si]                    ; Call command routine

exit:
        ret                                     ; Return to operating system

Strategy        ENDP

;**********************************************************************
;*------------------------------ Error -------------------------------*
;*                                                                    *
;*  HANDLE AN UNSUPPORTED REQUEST.                                    *
;*                                                                    *
;*  INPUT: ES:BX = address of request packet                          *
;*                                                                    *
;*  OUTPUT: status word set                                           *
;*                                                                    *
;*--------------------------------------------------------------------*
;**********************************************************************


Error           PROC    near

        mov     es:[bx].RP_Status, RP_StatusError + \
                                   RP_StatusDone + \
                                   RP_StatusUnknown ; OS/2 Unknown Command RC

        ret

Error           ENDP

;**********************************************************************
;*---------------------------- DummyRet ------------------------------*
;*                                                                    *
;*  HANDLE A REQUIRED BUT UNUSED REQUEST                              *
;*                                                                    *
;*  INPUT: ES:BX = address of request packet                          *
;*                                                                    *
;*  OUTPUT: status word set                                           *
;*                                                                    *
;*--------------------------------------------------------------------*
;**********************************************************************


DummyRet        PROC    near

        mov     es:[bx].RP_Status, RP_StatusDone  ; Indicate DONE

        ret

DummyRet        ENDP

;**********************************************************************
;*------------------------------ Open --------------------------------*
;*                                                                    *
;*  HANDLE AN OPEN REQUEST.                                           *
;*                                                                    *
;*  INPUT: ES:BX = address of request packet                          *
;*                                                                    *
;*  OUTPUT: status word set                                           *
;*                                                                    *
;*--------------------------------------------------------------------*
;**********************************************************************

Open            PROC    near

                ; no disabling of interrupts necessary

        cmp     UserCount, 0                    ; If not first user,
        jnz     short AddlUser                  ;    bypass initialization

        mov     Left8253, 0                     ; reset underrun counter

AddlUser:
        inc     UserCount                       ; Add another user

        mov     es:[bx].RP_Status, RP_StatusDone  ; Indicate DONE

        ret

Open            ENDP

;**********************************************************************
;*------------------------------ Close -------------------------------*
;*                                                                    *
;*  HANDLE A CLOSE REQUEST.                                           *
;*                                                                    *
;*  INPUT: ES:BX = address of request packet                          *
;*                                                                    *
;*  OUTPUT: status word set                                           *
;*                                                                    *
;*--------------------------------------------------------------------*
;**********************************************************************

Close           PROC    near

                ; no disabling of interrupts necessary

        cmp     UserCount, 0            ; If no users, don't do anything
        jz      short NoUsers

        dec     UserCount               ; Decrement number of users

NoUsers:
        mov     es:[bx].RP_Status, RP_StatusDone  ; Indicate DONE

        ret

Close           ENDP

;**********************************************************************
;*------------------------------ Read --------------------------------*
;*                                                                    *
;*  HANDLE A READ REQUEST.                                            *
;*                                                                    *
;*  INPUT: ES:BX = address of request packet                          *
;*                                                                    *
;*  OUTPUT: status word set                                           *
;*                                                                    *
;*--------------------------------------------------------------------*
;**********************************************************************

Read            PROC    near

        mov     si, es:[bx].RPR_BytesRequested ; Get buffer size
        cmp     si, 4                   ; At least one dword required
        jb      SetError                ; Caller's buffer is too small

        push    es                      ; Save packet pointer
        push    bx

        mov     cx, es:[bx].RPR_BytesRequested            ; Store ReadPacket
        mov     ax, word ptr es:[bx].RPR_TransferAddr + 2 ;   variables in
        mov     bx, word ptr es:[bx].RPR_TransferAddr     ;   registers

        mov     dh, 1                   ; 1 = Store result in ES:DI
        mov     dl, DevHlp_PhysToVirt   ; Use the PhysToVirt function
        call    DevHlpPtr               ; Call the Device Helper routine
        jc      DevHlpError

        cli                             ; Disable interrupts

        Read8253IntoAx                  ; Get current tick count

        cmp     ax, Last8253
        jbe     short ReadNoAdj         ; If underrun occurred:
        inc     Left8253                ;   increment underrun counter

ReadNoAdj:
        mov     Last8253, ax            ; Save current tick count

        not     ax                      ; Invert to get increasing values
        mov     cx, NanosInATickNum     ; Two stage multiply: low word first
        mul     cx
        push    dx                      ; Keep result: high word
        push    ax                      ;              low word

        mov     eax, Left8253           ; Get underrun counter as high dword

        sti                             ; Enable interrupts

        shl     ecx, 16                 ; Second stage: high dword
        mul     ecx                     ; Result in edx/eax

        pop     ebx                     ; Restore first stage result
        add     ebx, eax                ; Add low dword of second stage
        jnc     short ReadNoCy
        inc     edx

ReadNoCy:
        cmp     si, ReadDataLen         ; Complete record requested?
        jb      short ReadAltOut        ;   NO: output only one dword

        mov     ecx, NanosInATickDen * 1000000D ; Divide product by
                                        ; 1 million and NanosInATickDen

        mov     eax, edx                ; Use high dword modulus to
        xor     edx, edx                ;   prevent DIV INTR 0
        div     ecx                     ; (been open for 49.7 days)
        mov     eax, ebx                ; edxeax = edxebx MOD (ecx << 32)

        div     ecx
        mov     es:[di].RD_Millisecs, eax ; Quotient = Milliseconds

        mov     ecx, NanosInATickDen    ; Divide remainder
        mov     eax, edx                ;   by NanosInATickDen
        xor     edx, edx
        div     ecx

        mov     es:[di].RD_Nanosecs, eax ; Quotient = Nanoseconds

        mov     es:[di].RD_Version, HRTimerVersion
        mov     es:[di].RD_Revision, HRTimerRevision

        pop     bx                      ; Restore packet pointer
        pop     es

        mov     es:[bx].RPR_BytesRequested, ReadDataLen

        jmp     short GetOut

ReadAltOut:
        mov     ecx, NanosInATickDen * 1000D ; Divide Product by
                                        ; 1000 and NanosInATickDen

        mov     eax, edx                ; Use high dword modulus to
        xor     edx, edx                ;   prevent DIV INTR 0
        div     ecx                     ; (been open for 01:11:35)
        mov     eax, ebx                ; edxeax = edxebx MOD (ecx << 32)

        div     ecx
        mov     es:[di], eax            ; Output microseconds

        pop     bx                      ; Restore packet pointer
        pop     es

        mov     es:[bx].RPR_BytesRequested, 4

        jmp     short GetOut

DevHlpError:
        pop     bx                      ; Restore packet pointer
        pop     es

SetError:
        mov     es:[bx].RPR_BytesRequested, 0

GetOut:
        mov     es:[bx].RP_Status, RP_StatusDone

        ret

Read            ENDP

;**********************************************************************
;*---------------------------- Interrupt -----------------------------*
;*                                                                    *
;*  DEVICE DRIVER TIME-INTERRUPT ROUTINE. CALLED ON EACH OS/2 CLOCK   *
;*  TICK (MC146818 CHIP) VIA THE SetTimer DevHlp.                     *
;*                                                                    *
;*  INPUT: nothing                                                    *
;*                                                                    *
;*  OUTPUT: nothing                                                   *
;*                                                                    *
;*--------------------------------------------------------------------*
;**********************************************************************

Interrupt       PROC    far

        pushf                           ; Save flags

        cmp     UserCount, 0            ; If no users, no need to do anything
        jz      short NoUser

        push    ax                      ; Save register

        cli                             ; Disable interrupts

        Read8253IntoAx                  ; Get current tick count

        cmp     ax, Last8253
        jbe     short IntrNoAdj         ; if underrun occurred:
        inc     Left8253                ;   increment underrun counter

IntrNoAdj:
        mov     Last8253, ax            ; Keep current tick count

        sti                             ; Enable interrupts

        pop     ax                      ; Restore register

NoUser:
        popf                            ; Restore flags

        ret

Interrupt       ENDP

;**********************************************************************
;*---------------------------- Initialize ----------------------------*
;*                                                                    *
;*  DEVICE DRIVER INTIALIZATION ROUTINE (DISCARDED BY OS2 AFTER USE)  *
;*                                                                    *
;*  INPUT: ES:BX = address of init packet                             *
;*                                                                    *
;*  OUTPUT: nothing                                                   *
;*                                                                    *
;*--------------------------------------------------------------------*
;**********************************************************************

Initialize      PROC    near

        push    stdout                          ; Write copyright info
        push    ds
        push    offset CopyRightMsg
        push    CopyRightMsgLen
        push    ds
        push    offset BytesWritten
        call    DosWrite

        mov     eax, dword ptr es:[bx].RPI_CodeSegLen ; Save pointer to
        mov     DevHlpPtr , eax                 ;   Device Helper routine

        ; the initialization for timer 0 done here before is removed because:
        ; - the CLOCK$ device owns timer 0 and does its own initialization
        ; - it is currently exactly the same as what was done here before
        ;     (in both CLOCK01.SYS and CLOCK02.SYS)
        ; - if IBM decides to change the way timer 0 works we should not
        ;     override it as this may be vital for the system

        mov     ax, offset Interrupt            ; Our timer hook address
        mov     dl, DevHlp_SetTimer             ; SetTimer function
        call    DevHlpPtr                       ; Call Device Helper routine
        jnc     short NoError
                                                ; ****** ERROR ******
        push    stdout                          ; Write error message
        push    ds
        push    offset InitNotOkMsg
        push    InitNotOkMsgLen
        push    ds
        push    offset BytesWritten
        call    DosWrite

        mov     es:[bx].RPI_NumberUnits, 0      ; Zero these fields so OS/2
        mov     es:[bx].RPI_CodeSegLen, 0       ;    knows to cancel this
        mov     es:[bx].RPI_DataSegLen, 0       ;    device driver

        mov     es:[bx].RP_Status, RP_StatusError + \
                                   RP_StatusDone + \
                                   RP_StatusGenFail ; General Failure error

        jmp     short InitExit                  ; **** END ERROR ****

NoError:
        mov     es:[bx].RPI_CodeSegLen, offset Initialize   ; End of code seg
        mov     es:[bx].RPI_DataSegLen, offset CopyRightMsg ; End of data seg

        mov     word ptr es:[bx].RP_Status, RP_StatusDone   ; Indicate DONE

InitExit:
        ret

Initialize      ENDP

_TEXT           ENDS

END

;**********************************************************************
;*                       END OF SOURCE CODE                           *
;**********************************************************************
