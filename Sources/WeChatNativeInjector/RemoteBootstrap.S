#if defined(__arm64__) && !defined(__arm64e__)
.text
.p2align 2
.globl _wechat_remote_code_start
.globl _wechat_remote_worker
.globl _wechat_remote_code_end
.private_extern _wechat_remote_code_start
.private_extern _wechat_remote_worker
.private_extern _wechat_remote_code_end

// x0 = remote Context. Only the pthread SPI may run on this raw Mach thread.
_wechat_remote_code_start:
    mov x19, x0
    add x0, x19, #40
    mov x1, #0
    ldr x2, [x19, #32]
    mov x3, x19
    ldr x16, [x19, #24]
    blr x16
    str w0, [x19, #56]
    mov w8, #1
    add x9, x19, #60
    stlr w8, [x9]
1:  b 1b // Controller terminates this thread after bootstrapDone is published.

// A real pthread now supplies the TLS required by dyld, Foundation and C++.
_wechat_remote_worker:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    mov x19, x0
    ldr x16, [x19, #96] // pthread_self
    blr x16
    ldr x16, [x19, #88] // pthread_detach
    blr x16
    ldr x0, [x19, #0]
    mov x1, #2 // RTLD_NOW
    ldr x16, [x19, #8]
    blr x16
    str x0, [x19, #48]
    cbz x0, 2f
    ldr x1, [x19, #80]
    ldr x16, [x19, #16]
    blr x16 // dlsym(handle, native_attach)
    cbz x0, 3f
    mov x16, x0
    blr x16
    str w0, [x19, #68]
    cmp w0, #2
    b.ne 7f
    ldr x0, [x19, #48]
    ldr x1, [x19, #624] // native_patch_plan symbol
    ldr x16, [x19, #16]
    blr x16
    cbz x0, 3f
    mov x16, x0
    blr x16
    cbz x0, 3f
    str x0, [x19, #640]
    mov w8, #1
    add x9, x19, #636
    stlr w8, [x9] // patch_requested
    mov w20, #15000
8:  add x9, x19, #632
    ldar w8, [x9] // controller acknowledgement
    cbnz w8, 9f
    mov x0, #1000
    ldr x16, [x19, #648] // usleep
    blr x16
    subs w20, w20, #1
    b.ne 8b
    mov w8, #-18
    str w8, [x19, #68]
    b 5f
9:  cmp w8, #1
    b.ne 10f
    ldr x0, [x19, #48]
    ldr x1, [x19, #80]
    ldr x16, [x19, #16]
    blr x16
    cbz x0, 3f
    mov x16, x0
    blr x16 // native_attach validates the applied branches and commits features
    str w0, [x19, #68]
    b 7f
10: mov w8, #-18
    str w8, [x19, #68]
    b 5f
7:  ldr w8, [x19, #68]
    cmp w8, #1
    b.eq 5f
    ldr x0, [x19, #48]
    ldr x1, [x19, #616] // native_last_error symbol
    ldr x16, [x19, #16]
    blr x16
    cbz x0, 5f
    mov x16, x0
    blr x16
    b 11f
2:  mov w8, #-2
    b 4f
3:  mov w8, #-3
4:  str w8, [x19, #68]
    ldr x16, [x19, #72] // dlerror, copy before pthread TLS is destroyed.
    blr x16
11:
    cbz x0, 5f
    add x9, x19, #104
    mov x10, #511
6:  ldrb w8, [x0], #1
    strb w8, [x9], #1
    cbz w8, 5f
    subs x10, x10, #1
    b.ne 6b
5:  mov w8, #1
    add x9, x19, #64
    stlr w8, [x9]
    mov x0, #0
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret
_wechat_remote_code_end:
#endif
