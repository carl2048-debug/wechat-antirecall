#pragma once
#include <stddef.h>
#include <sys/types.h>
#include <stdint.h>

uint64_t wechat_process_start_token(pid_t pid);

// Select only the exact main executable, never renderer/helper processes.
pid_t wechat_find_main_process(const char *executable);
int wechat_inject_runtime(pid_t pid, const char *executable, const char *dylib,
                          char *error, size_t error_size);
