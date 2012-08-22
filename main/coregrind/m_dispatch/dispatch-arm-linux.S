/*--------------------------------------------------------------------*/
/*--- The core dispatch loop, for jumping to a code address.       ---*/
/*---                                         dispatch-arm-linux.S ---*/
/*--------------------------------------------------------------------*/

/*
  This file is part of Valgrind, a dynamic binary instrumentation
  framework.

  Copyright (C) 2008-2011 Evan Geller
     gaze@bea.ms
  Copyright (C) 2011 John Reiser
     jreiser@BitWagon.com
     Sept+Oct 2011:  Inner loops recoded.  Set kernel tls pointer from user's.
  This program is free software; you can redistribute it and/or
  modify it under the terms of the GNU General Public License as
  published by the Free Software Foundation; either version 2 of the
  License, or (at your option) any later version.

  This program is distributed in the hope that it will be useful, but
  WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
  General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program; if not, write to the Free Software
  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA
  02111-1307, USA.

  The GNU General Public License is contained in the file COPYING.
*/

#if defined(VGP_arm_linux)
	.fpu vfp

#include "pub_core_basics_asm.h"
#include "pub_core_dispatch_asm.h"
#include "pub_core_transtab_asm.h"
#include "libvex_guest_offsets.h"	/* for OFFSET_arm_R* */

.text
// Kernel puts a user-executable subroutine at 0xffff0fe0 to return the value
// of the Thread Local Storage (tls) pointer.
__aeabi_read_tp: .globl __aeabi_read_tp  // Code copied from glibc-2.13.
	mvn r0,#0xf000  // 0xffff0fff
	sub pc,r0,#31  // goto 0xffff0fe0: __kuser_get_tls

// System call to change the tls pointer that is returned by (*0xffff0fe0)().
real_sys_set_tls: .globl real_sys_set_tls
	mov ip,r7
	mov r7,#0xf0000
	orr r7,r7,#5  // 983045
	svc 0
	mov r7,ip
	bx lr

/*------------------------------------------------------------*/
/*---                                                      ---*/
/*--- The dispatch loop.  VG_(run_innerloop) is used to    ---*/
/*--- run all translations except no-redir ones.           ---*/
/*---                                                      ---*/
/*------------------------------------------------------------*/

/*----------------------------------------------------*/
/*--- Preamble (set everything up)                 ---*/
/*----------------------------------------------------*/

/* signature:
UWord VG_(run_innerloop) ( void* guest_state, UWord do_profiling );
*/
.text
.globl VG_(run_innerloop)
VG_(run_innerloop):
	push {r0, r1, r4, r5, r6, r7, r8, r9, fp, lr}
         /* r0 (hence also [sp,#0]) holds guest_state */
         /* r1 holds do_profiling */
	mov r8, r0
	mov r9, r1
 
#if (ARM_ARCH_V6 | ARM_ARCH_V7)  /*{*/

        /* set FPSCR to vex-required default value */
        mov  r4, #0
        fmxr fpscr, r4
#endif  /*}*/
#if ARM_ARCH_V5TE  /*{*/
	// Propagate user tls pointer to kernel.
	ldr r4, [r8, #OFFSET_arm_TPIDRURO]  // our assumed tls pointer
	bl __aeabi_read_tp                  // kernel's cached pointer
	cmp r0, r4; beq 0f
	mov r0, r4; bl real_sys_set_tls    // update kernel's cache
0:
#endif  /*}*/

	ldr r0, [r8, #OFFSET_arm_R15T]
        
       	/* fall into main loop (the right one) */
	cmp r9, #0      /* do_profiling */
	bne VG_(run_innerloop__dispatch_profiled)
	// FALLTHRUOGH  b VG_(run_innerloop__dispatch_unprofiled)


/*----------------------------------------------------*/
/*--- NO-PROFILING (standard) dispatcher           ---*/
/*----------------------------------------------------*/

// Pairing of insns below is how dual dispatch should work.
  
CLR_HI= 32 - VG_TT_FAST_BITS
CLR_LO= 32 - VG_TT_FAST_BITS
 
.global	VG_(run_innerloop__dispatch_unprofiled)
VG_(run_innerloop__dispatch_unprofiled):

	/* AT ENTRY: r0 is next guest addr, r8 is possibly
        modified guest state ptr */

#if defined(ARM_ARCH_V6)
		/* use slower code on pre-cortex architectures */
        ldr r3, =VG_(dispatch_ctr)
        tst  r8, #1
#else

        tst  r8, #1
        ldr  r2,=VG_(dispatch_ctr)
#endif
        bne  gsp_changed                // guest state pointer was modified
	movs r3, r0, LSR #1             // shift off Thumb mode bit; set Carry

	ldr  r5,=VG_(tt_fast)
	movcc  r3, r3, LSR #1           // if ARM mode then shift off another bit

	ldr  r1, [r2]                   // dispatch_ctr
	mov  r3, r3, LSL #CLR_HI        // shift off hi bits

        str  r0, [r8, #OFFSET_arm_R15T]  // save jump address into guest state
	add  r5, r5, r3, LSR #CLR_LO -3 // r5= &tt_fast[entry#]

        ldr  r4, [r5, #0]               // r4= .guest
        subs r1, r1, #1                 // decrement timeslice

        ldr  r5, [r5, #4]               // r5= .host
        beq  counter_is_zero            // out of timeslice ==> defer to scheduler

        adr  lr, VG_(run_innerloop__dispatch_unprofiled)  // &continuation
	cmp  r4, r0                     // check cache tag

#if defined(ARM_ARCH_V6)
		/* use slower code on pre-cortex architectures */
        ldr r1, =VG_TT_FAST_MASK       // r1 = VG_TT_FAST_MASK
        ldr r4, =VG_(tt_fast)
        and  r2, r1, r0, LSR #1        // r2 = entry #
#else
        streq  r1, [r2]                 // match: update dispatch_ctr
	bxeq r5                         // match: jump to .host, continue at *lr
#endif

        // r5: next-host    r8: live, gsp
        // r4: next-guest
        // r2: &VG_(dispatch_ctr)
	// r1:  VG_(dispatch_ctr)
        // LIVE: r5, r8; all others dead
fast_lookup_failed:
	movne  r0, #VG_TRC_INNER_FASTMISS
counter_is_zero:
        moveq  r0, #VG_TRC_INNER_COUNTERZERO

/* All exits from the dispatcher go through here.  %r0 holds
   the return value. 
*/
run_innerloop_exit:
#if (ARM_ARCH_V6 | ARM_ARCH_V7)  /*{*/
        /* We're leaving.  Check that nobody messed with
           FPSCR in ways we don't expect. */
        fmrx r4, fpscr
        bic  r4, #0xF8000000 /* mask out NZCV and QC */
        bic  r4, #0x0000009F /* mask out IDC,IXC,UFC,OFC,DZC,IOC */
        cmp  r4, #0
	cmp  r4, r4  // nofp
invariant_violation:
        movne  r0, #VG_TRC_INVARIANT_FAILED
#endif  /*}*/

run_innerloop_exit_REALLY:
	add sp, sp, #8
	pop {r4, r5, r6, r7, r8, r9, fp, pc}             
	/*NOTREACHED*/

.ltorg

/*----------------------------------------------------*/
/*--- PROFILING dispatcher (can be much slower)    ---*/
/*----------------------------------------------------*/

.global	VG_(run_innerloop__dispatch_profiled)
VG_(run_innerloop__dispatch_profiled):
	/* AT ENTRY: r0 is next guest addr, r8 is possibly
        modified guest state ptr */

#if defined(ARM_ARCH_V6)
		/* use slower code on pre-cortex architectures */
        ldr r3, =VG_(dispatch_ctr)
        tst  r8, #1
#else
        tst  r8, #1
	ldr  r2,=VG_(dispatch_ctr)

        bne  gsp_changed                // guest state pointer was modified
	movs r3, r0, LSR #1             // shift off Thumb mode bit; set Carry
#endif

	ldr  r5,=VG_(tt_fast)
	movcc  r3, r3, LSR #1           // if ARM mode then shift off another bit

	ldr  r1, [r2]                   // dispatch_ctr
	mov  r3, r3, LSL #CLR_HI        // shift off hi bits

        str  r0, [r8, #OFFSET_arm_R15T]  // save jump address into guest state
	add  r5, r5, r3, LSR #CLR_LO -3 // r5= &tt_fast[entry#]

        ldr  r4, [r5, #0]               // r4= .guest
        subs r1, r1, #1                 // decrement timeslice

        ldr  r5, [r5, #4]               // r5= .host
        beq  counter_is_zero            // out of timeslice ==> defer to scheduler

        cmp  r4, r0                     // check cache tag
	ldr  r0, =VG_(tt_fastN)

#if defined(ARM_ARCH_V6)
		/* use slower code on pre-cortex architectures */
        ldr r1, =VG_TT_FAST_MASK       // r1 = VG_TT_FAST_MASK
        ldr r4, =VG_(tt_fast)
		and  r2, r1, r0, LSR #1         // r2 = entry #
#else
        streq  r1, [r2]                 // match: update dispatch_ctr
	bne fast_lookup_failed

	ldr  r0, [r0, r3, LSR #CLR_LO -2]  // tt_fastN[entry#]
	adr  lr, VG_(run_innerloop__dispatch_profiled)  // &continuation
// r0 stall
	ldr  r3, [r0]
// r3 stall
	add  r3, r3, #1
#endif	
#if defined(ARM_ARCH_V6)
		/* use slower code on pre-cortex architectures */
        ldr r0, =VG_(tt_fastN)
#else
        str  r3, [r0]
	bx  r5                         // match: jump to .host, continue at *lr
#endif
           
	/*NOTREACHED*/

/*----------------------------------------------------*/
/*--- exit points                                  ---*/
/*----------------------------------------------------*/

gsp_changed:
        // r0 = next guest addr (R15T), r8 = modified gsp
        /* Someone messed with the gsp.  Have to
           defer to scheduler to resolve this.  dispatch ctr
           is not yet decremented, so no need to increment. */
        /* R15T is NOT up to date here.  First, need to write
           r0 back to R15T, but without trashing r8 since
           that holds the value we want to return to the scheduler.
           Hence use r1 transiently for the guest state pointer. */
	ldr r1, [sp, #0]
	str r0, [r1, #OFFSET_arm_R15T]
	mov r0, r8      // "return modified gsp"
	b run_innerloop_exit
        /*NOTREACHED*/

.size VG_(run_innerloop), .-VG_(run_innerloop)


/*------------------------------------------------------------*/
/*---                                                      ---*/
/*--- A special dispatcher, for running no-redir           ---*/
/*--- translations.  Just runs the given translation once. ---*/
/*---                                                      ---*/
/*------------------------------------------------------------*/

/* signature:
void VG_(run_a_noredir_translation) ( UWord* argblock );
*/

/* Run a no-redir translation.  argblock points to 4 UWords, 2 to carry args
   and 2 to carry results:
      0: input:  ptr to translation
      1: input:  ptr to guest state
      2: output: next guest PC
      3: output: guest state pointer afterwards (== thread return code)
*/
.global VG_(run_a_noredir_translation)
VG_(run_a_noredir_translation):
	push {r0,r1 /* EABI compliance */, r4-r12, lr} 
	ldr r8, [r0, #4]
	mov lr, pc
	ldr pc, [r0, #0]

	pop {r1}
	str r0, [r1, #8]
	str r8, [r1, #12]
	pop {r1/*EABI compliance*/,r4-r12, pc}	

.size VG_(run_a_noredir_translation), .-VG_(run_a_noredir_translation)

/* Let the linker know we don't need an executable stack */
.section .note.GNU-stack,"",%progbits

#endif // defined(VGP_arm_linux)

/*--------------------------------------------------------------------*/
/*--- end                                     dispatch-arm-linux.S ---*/
/*--------------------------------------------------------------------*/
