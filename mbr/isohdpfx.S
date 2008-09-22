/* -----------------------------------------------------------------------
 *
 *   Copyright 2007-2008 H. Peter Anvin - All Rights Reserved
 *
 *   Permission is hereby granted, free of charge, to any person
 *   obtaining a copy of this software and associated documentation
 *   files (the "Software"), to deal in the Software without
 *   restriction, including without limitation the rights to use,
 *   copy, modify, merge, publish, distribute, sublicense, and/or
 *   sell copies of the Software, and to permit persons to whom
 *   the Software is furnished to do so, subject to the following
 *   conditions:
 *
 *   The above copyright notice and this permission notice shall
 *   be included in all copies or substantial portions of the Software.
 *
 *   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
 *   EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
 *   OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
 *   NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
 *   HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
 *   WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 *   FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
 *   OTHER DEALINGS IN THE SOFTWARE.
 *
 * ----------------------------------------------------------------------- */

/*
 * Modified MBR code used on an ISO image in hybrid mode.
 *
 * This doesn't follow the El Torito spec at all -- it is just a stub
 * loader of a hard-coded offset, but that's good enough to load
 * ISOLINUX.
 */
	
	.code16
	.text

HYBRID_MAGIC			= 0x7078c0fb
isolinux_hybrid_signature 	= 0x7c00+64
isolinux_start_hybrid		= 0x7c00+64+4

	.globl	bootsec
/* Important: the top 6 words on the stack are passed to isolinux.bin */
stack		= 0x7c00
driveno		= (stack-6)
ebios_flag	= (stack-8)
sectors		= (stack-10)
heads		= (stack-12)
secpercyl	= (stack-16)

BIOS_page = 0x462

	/* gas/ld has issues with doing this as absolute addresses... */
	.section ".bootsec", "a", @nobits
	.globl	bootsec
bootsec:
	.space	512

	.text
	.globl	_start
_start:

	cli
	xorw	%ax, %ax
	movw	%ax, %ds
	movw	%ax, %ss
	movw	$stack, %sp
	movw	%sp, %si
	pushw	%es		/* es:di -> $PnP header */
	pushw	%di
	pushw	%dx		/* dl -> drive number */
	movw	%ax, %es
	sti
	cld

	/* Copy down to 0:0x600 */
	movw	$_start, %di
	movw	$(512/2), %cx
	rep; movsw

	ljmpw	$0, $next

next:
	/* Check to see if we have EBIOS */
	pushw	%dx		/* drive number */
	movb	$0x41, %ah	/* %al == 0 already */
	movw	$0x55aa, %bx
	xorw	%cx, %cx
	xorb	%dh, %dh
	stc
	int	$0x13
	jc	1f
	cmpw	$0xaa55, %bx
	jne	1f
	andw	$1,%cx		/* Bit 0 = fixed disk subset */
	jz	1f

	/* We have EBIOS; patch in the following code at
	   read_sector_cbios: movb $0x42, %ah ;  jmp read_common */
	movl	$0xeb42b4+((read_common-read_sector_cbios-4) << 24), \
		(read_sector_cbios)

1:
	popw	%dx
	pushw	%cx		/* Save EBIOS flag */

	/* Get (C)HS geometry */
	movb	$0x08, %ah
	int	$0x13
	andw	$0x3f, %cx	/* Sector count */
	pushw	%cx		/* Save sectors on the stack */
	movzbw	%dh, %ax	/* dh = max head */
	incw	%ax		/* From 0-based max to count */
	pushw	%ax		/* Save heads on the stack */
	mulw	%cx		/* Heads*sectors -> sectors per cylinder */

	/* Save sectors/cylinder on the stack */
	pushw	%dx		/* High word */
	pushw	%ax		/* Low word */

	/*
	 * Load sectors.  We do this one at a time mostly to avoid
	 * pitfalls and to share code with the stock MBR code.
	 */
	movw	$0x7c00, %bx
	movw	$4, %cx		/* Sector count */
	movl	(lba_offset), %eax

2:
	call	read_sector
	jc	disk_error
	incl	%eax
	addb	$(512 >> 8), %bh
	loopw	2b

	/*
	 * Okay, that actually worked... update the stack pointer
	 * and jump into isolinux.bin...
	 */
	cmpl	$HYBRID_MAGIC,(isolinux_hybrid_signature)
	jne	bad_signature
	
	cli
	movw	$heads, %sp
	jmp	isolinux_start_hybrid

bad_signature:
	call	error
	.ascii	"isolinux.bin missing or corrupt.\r\n"

/*
 * read_sector: read a single sector pointed to by %eax to %es:%bx.
 * CF is set on error.  All registers saved.
 */
read_sector:
	pushal
	xorl	%edx, %edx
	pushl	%edx	/* MSW of LBA */
	pushl	%eax	/* LSW of LBA */
	pushw	%es	/* Buffer segment */
	pushw	%bx	/* Buffer offset */
	pushw	$1	/* Sector count */
	pushw	$16	/* Size of packet */
	movw	%sp, %si

	/* This chunk is skipped if we have ebios */
	/* Do not clobber %eax before this chunk! */
	/* This also relies on %bx and %edx as set up above. */
read_sector_cbios:
	divl	(secpercyl)
	shlb	$6, %ah
	movb	%ah, %cl
	movb	%al, %ch
	xchgw	%dx, %ax
	divb	(sectors)
	movb	%al, %dh
	orb	%ah, %cl
	incw	%cx	/* Sectors are 1-based */
	movw	$0x0201, %ax

read_common:
	movb	(driveno), %dl
	int	$0x13
	leaw	16(%si), %sp	/* Drop DAPA */
	popal
	ret

disk_error:
	call	error
	.ascii	"Operating system load error.\r\n"

/*
 * Print error messages.  This is invoked with "call", with the
 * error message at the return address.
 */
error:
	popw	%si
2:
	lodsb
	movb	$0x0e, %ah
	movb	(BIOS_page), %bh
	movb	$0x07, %bl
	int	$0x10		/* May destroy %bp */
	cmpb	$10, %al	/* Newline? */
	jne	2b

	int	$0x18		/* Boot failure */
die:
	hlt
	jmp	die

	/* Address of pointer to isolinux.bin */
lba_offset = _start+432