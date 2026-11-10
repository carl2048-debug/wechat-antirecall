#pragma once
#include <stdint.h>

// Called only after the existing receive hook has been installed successfully.
void wechat_antirecall_red_packet_initialize(uintptr_t slide, const char *build);
void wechat_antirecall_red_packet_observe(void *message, int mode);
extern "C" bool wechat_antirecall_red_packet_available(void);
