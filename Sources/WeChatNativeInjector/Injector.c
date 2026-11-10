#include "WeChatNativeInjector.h"
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach/arm/thread_status.h>
#include <mach-o/dyld_images.h>
#include <mach-o/loader.h>
#include <libproc.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/ptrace.h>
#include <sys/wait.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>

// Darwin code-signing status API (published in XNU, absent from the public SDK).
extern int csops(pid_t, unsigned int, void *, size_t);
enum { WeChatCSStatus = 0, WeChatCSDebugged = 0x10000000 };

uint64_t wechat_process_start_token(pid_t pid) {
    struct proc_bsdinfo info = {0};
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) return 0;
    return info.pbi_start_tvsec * 1000000ULL + info.pbi_start_tvusec;
}

pid_t wechat_find_main_process(const char *executable) {
    int size = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (size <= 0) return -1;
    size += 4096;
    pid_t *pids = calloc(1, (size_t)size);
    if (!pids) return -1;
    int count = proc_listpids(PROC_ALL_PIDS, 0, pids, size) / sizeof(pid_t);
    pid_t found = 0;
    for (int i = 0; i < count; ++i) {
        char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
        if (pids[i] > 0 && proc_pidpath(pids[i], path, sizeof(path)) > 0 &&
            strcmp(path, executable) == 0) {
            if (found) { found = -2; break; }
            found = pids[i];
        }
    }
    free(pids);
    return found;
}

#if defined(__arm64__) && !defined(__arm64e__)
extern const unsigned char wechat_remote_code_start[], wechat_remote_worker[], wechat_remote_code_end[];
typedef struct {
    uint64_t path, dlopen_fn, dlsym_fn, create_fn, worker, pthread, handle;
    int32_t create_result;
    uint32_t bootstrap_done, worker_done;
    int32_t hook_status;
    uint64_t dlerror_fn, init_name, detach_fn, self_fn;
    char error[512];
    uint64_t error_name, plan_name;
    int32_t patch_ack;
    uint32_t patch_requested;
    uint64_t plan_address, sleep_fn;
} Context;
_Static_assert(offsetof(Context, bootstrap_done) == 60, "bootstrap ABI");
_Static_assert(offsetof(Context, hook_status) == 68, "worker ABI");
_Static_assert(offsetof(Context, error) == 104, "error ABI");
_Static_assert(offsetof(Context, patch_ack) == 632 && offsetof(Context, sleep_fn) == 648, "patch handshake ABI");

static int read_remote(task_t task, uint64_t address, void *buffer, size_t size) {
    mach_vm_size_t actual = 0;
    return mach_vm_read_overwrite(task, address, size, (mach_vm_address_t)buffer, &actual) == KERN_SUCCESS && actual == size;
}
static kern_return_t write_remote(task_t task, uint64_t address, const void *bytes, size_t size) {
    return mach_vm_write(task, address, (vm_offset_t)bytes, (mach_msg_type_number_t)size);
}
static int dyld_info(task_t task, struct dyld_all_image_infos *info) {
    task_dyld_info_data_t data = {0};
    mach_msg_type_number_t count = TASK_DYLD_INFO_COUNT;
    if (task_info(task, TASK_DYLD_INFO, (task_info_t)&data, &count) != KERN_SUCCESS ||
        data.all_image_info_format != TASK_DYLD_ALL_IMAGE_INFO_64 ||
        data.all_image_info_size < offsetof(struct dyld_all_image_infos, sharedCacheBaseAddress) + sizeof(uint64_t)) return 0;
    memset(info, 0, sizeof(*info));
    size_t size = data.all_image_info_size < sizeof(*info) ? data.all_image_info_size : sizeof(*info);
    return read_remote(task, data.all_image_info_addr, info, size);
}
static uint64_t shared_symbol(task_t task, const char *name) {
    void *symbol = dlsym(RTLD_DEFAULT, name);
    Dl_info info = {0};
    unsigned char bytes[16];
    if (!symbol || !dladdr(symbol, &info) || !info.dli_fbase ||
        !(((const struct mach_header_64 *)info.dli_fbase)->flags & MH_DYLIB_IN_CACHE) ||
        !read_remote(task, (uint64_t)symbol, bytes, sizeof(bytes)) ||
        memcmp(symbol, bytes, sizeof(bytes)) != 0) return 0;
    return (uint64_t)symbol;
}
static double monotonic_seconds(void) {
    struct timespec value;
    clock_gettime(CLOCK_MONOTONIC, &value);
    return value.tv_sec + value.tv_nsec / 1e9;
}

typedef struct { uint64_t entry; uint32_t expected, branch; } PatchRecord;
typedef struct { uint32_t version, count; PatchRecord records[2]; } PatchPlan;
_Static_assert(sizeof(PatchPlan) == 40, "patch plan ABI");

// No target thread can execute a page during its temporary RW (non-executable)
// interval. The controller never requests RWX for existing target code.
static int apply_patch_plan(task_t task, uint64_t address, char *error, size_t error_size) {
    PatchPlan plan = {0};
    if (!read_remote(task, address, &plan, sizeof(plan)) || plan.version != 1 || !plan.count || plan.count > 2) {
        snprintf(error, error_size, "读取入口写入计划失败或计划格式不匹配");
        return 0;
    }
    for (unsigned i = 0; i < plan.count; ++i) {
        if ((plan.records[i].entry & 3) || (plan.records[i].branch & 0xfc000000) != 0x14000000) {
            snprintf(error, error_size, "入口写入计划中的地址或跳转指令无效");
            return 0;
        }
    }
    kern_return_t kr = task_suspend(task);
    if (kr != KERN_SUCCESS) {
        snprintf(error, error_size, "暂停微信以写入入口失败：%s（kr=%d）", mach_error_string(kr), kr);
        return 0;
    }
    uint32_t previous[2] = {0};
    vm_prot_t protection[2] = {0};
    int changed[2] = {0}, page_touched[2] = {0};
    int ok = 1, restored = 1;
    size_t page_size = (size_t)getpagesize();
    for (unsigned i = 0; i < plan.count; ++i) {
        PatchRecord *record = &plan.records[i];
        if (!read_remote(task, record->entry, &previous[i], 4) ||
            (previous[i] != record->expected && previous[i] != record->branch)) {
            snprintf(error, error_size, "暂停后入口指令不匹配：0x%llx", (unsigned long long)record->entry);
            ok = 0; break;
        }
        if (previous[i] == record->branch) continue;
        mach_vm_address_t region = record->entry;
        mach_vm_size_t size = 0;
        vm_region_basic_info_data_64_t info = {0};
        mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t object = MACH_PORT_NULL;
        kr = mach_vm_region(task, &region, &size, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &count, &object);
        if (object != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object);
        if (kr != KERN_SUCCESS || !(info.protection & VM_PROT_EXECUTE)) {
            snprintf(error, error_size, "读取入口可执行页权限失败：kr=%d", kr);
            ok = 0; break;
        }
        protection[i] = info.protection;
        mach_vm_address_t page = record->entry & ~((uint64_t)page_size - 1);
        kr = mach_vm_protect(task, page, page_size, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
        if (kr != KERN_SUCCESS) {
            snprintf(error, error_size, "入口页转为私有 RW 失败：0x%llx，%s（kr=%d，maxprot=%d）",
                (unsigned long long)page, mach_error_string(kr), kr, info.max_protection);
            ok = 0; break;
        }
        page_touched[i] = 1;
        // Record before the write so even an unexpected partial kernel copy is
        // included in rollback. Reads/writes are aligned four-byte operations.
        changed[i] = 1;
        kr = write_remote(task, record->entry, &record->branch, 4);
        if (kr != KERN_SUCCESS) {
            snprintf(error, error_size, "写入入口跳转失败：%s（kr=%d）", mach_error_string(kr), kr);
            ok = 0; break;
        }
        kr = mach_vm_protect(task, page, page_size, FALSE, protection[i]);
        if (kr != KERN_SUCCESS) {
            snprintf(error, error_size, "恢复入口页执行权限失败：%s（kr=%d）", mach_error_string(kr), kr);
            ok = 0; break;
        }
    }
    if (!ok) {
        for (unsigned i = plan.count; i-- > 0;) {
            if (!page_touched[i]) continue;
            mach_vm_address_t page = plan.records[i].entry & ~((uint64_t)page_size - 1);
            if (changed[i]) {
                kr = mach_vm_protect(task, page, page_size, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
                if (kr != KERN_SUCCESS || write_remote(task, plan.records[i].entry, &previous[i], 4) != KERN_SUCCESS) restored = 0;
            }
            if (mach_vm_protect(task, page, page_size, FALSE, protection[i]) != KERN_SUCCESS) {
                snprintf(error, error_size, "入口页执行权限无法恢复，微信保持暂停；请强制退出并重新打开微信");
                return -1; // Never resume a target with a formerly executable page left NX.
            }
        }
    }
    kr = task_resume(task);
    if (kr != KERN_SUCCESS) {
        snprintf(error, error_size, "恢复微信运行失败：%s（kr=%d），请重新打开微信", mach_error_string(kr), kr);
        return -1;
    }
    if (!restored) snprintf(error, error_size, "部分入口无法回滚；进程已恢复运行，请重启微信后再注入");
    return ok && restored;
}
#endif

int wechat_inject_runtime(pid_t pid, const char *executable, const char *dylib,
                          char *error, size_t error_size) {
#define FAIL(...) do { snprintf(error, error_size, __VA_ARGS__); goto cleanup; } while (0)
#if defined(__arm64__) && !defined(__arm64e__)
    int result = 0, lock_fd = -1, thread_started = 0, attached = 0;
    task_t task = MACH_PORT_NULL;
    thread_act_t thread = MACH_PORT_NULL;
    mach_vm_address_t data = 0, code = 0, stack = 0;
    size_t page = (size_t)getpagesize(), stack_size = 256 * 1024;
    char lock_path[128], actual_path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    Context context = {0};
    const char entry_name[] = "wechat_antirecall_native_attach";
    const char error_name[] = "wechat_antirecall_native_last_error";
    const char plan_name[] = "wechat_antirecall_native_patch_plan";
    size_t data_size = ((sizeof(context) + sizeof(entry_name) + sizeof(error_name) + sizeof(plan_name) + strlen(dylib) + 1 + page - 1) / page) * page;
    size_t code_size = (size_t)(wechat_remote_code_end - wechat_remote_code_start);
    if (data_size > 4 * page || code_size > page) FAIL("注入参数过长");
    if (pid <= 0 || pid == getpid() || proc_pidpath(pid, actual_path, sizeof(actual_path)) <= 0 ||
        strcmp(actual_path, executable) != 0) FAIL("微信主进程已退出或路径不匹配，请重试");
    snprintf(lock_path, sizeof(lock_path), "/private/tmp/wechat-antirecall-inject-%d.lock", pid);
    lock_fd = open(lock_path, O_CREAT | O_RDONLY | O_NOFOLLOW | O_CLOEXEC, 0600);
    struct stat lock_stat;
    if (lock_fd < 0 || fstat(lock_fd, &lock_stat) || !S_ISREG(lock_stat.st_mode) ||
        flock(lock_fd, LOCK_EX | LOCK_NB)) FAIL("该微信进程正在注入或无法取得注入锁");
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr != KERN_SUCCESS) FAIL("无法取得微信进程控制权限：%s。请从 GUI 授权管理员操作；系统保护仍可能拒绝注入。", mach_error_string(kr));
    struct dyld_all_image_infos local, remote;
    if (!dyld_info(mach_task_self(), &local) || !dyld_info(task, &remote) ||
        !local.sharedCacheBaseAddress || local.sharedCacheBaseAddress != remote.sharedCacheBaseAddress ||
        local.sharedCacheSlide != remote.sharedCacheSlide ||
        memcmp(local.sharedCacheUUID, remote.sharedCacheUUID, 16)) FAIL("微信与注入器的系统共享缓存不匹配；只支持原生 arm64 微信");
    struct dyld_image_info main_image;
    struct mach_header_64 main_header;
    if (!remote.infoArrayCount || !read_remote(task, (uint64_t)remote.infoArray, &main_image, sizeof(main_image)) ||
        !read_remote(task, (uint64_t)main_image.imageLoadAddress, &main_header, sizeof(main_header)) ||
        main_header.magic != MH_MAGIC_64 || main_header.cputype != CPU_TYPE_ARM64 ||
        (main_header.cpusubtype & ~CPU_SUBTYPE_MASK) == CPU_SUBTYPE_ARM64E) FAIL("只支持原生 arm64 微信进程，不支持 Rosetta 或 arm64e");
    context.dlopen_fn = shared_symbol(task, "dlopen");
    context.dlsym_fn = shared_symbol(task, "dlsym");
    context.dlerror_fn = shared_symbol(task, "dlerror");
    context.create_fn = shared_symbol(task, "pthread_create_from_mach_thread");
    context.detach_fn = shared_symbol(task, "pthread_detach");
    context.self_fn = shared_symbol(task, "pthread_self");
    context.sleep_fn = shared_symbol(task, "usleep");
    if (!context.dlopen_fn || !context.dlsym_fn || !context.dlerror_fn ||
        !context.create_fn || !context.detach_fn || !context.self_fn || !context.sleep_fn) FAIL("远程系统函数校验失败，未执行注入");
    // Anonymous executable pages must be permitted before starting a remote
    // thread. Native ptrace sets the process-only DEBUGGED state, as a debugger
    // would. It does not alter the on-disk signature or relax global policy.
    uint32_t csflags = 0;
    if (csops(pid, WeChatCSStatus, &csflags, sizeof(csflags))) FAIL("无法读取微信代码签名运行状态");
    if (!(csflags & WeChatCSDebugged)) {
        struct proc_bsdinfo bsd = {0};
        if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, sizeof(bsd)) != sizeof(bsd) ||
            (bsd.pbi_flags & PROC_FLAG_TRACED) || bsd.pbi_status == 4) FAIL("微信已被其他调试器控制或已暂停，请先恢复微信");
        if (ptrace(PT_ATTACHEXC, pid, NULL, 0)) FAIL("系统拒绝原生调试授权：%s；未执行远程代码", strerror(errno));
        attached = 1;
        int status = 0, stopped = 0;
        double attach_deadline = monotonic_seconds() + 3;
        while (monotonic_seconds() < attach_deadline) {
            pid_t waited = waitpid(pid, &status, WNOHANG | WUNTRACED);
            if (waited == pid) { stopped = WIFSTOPPED(status); break; }
            if (waited < 0 && errno != EINTR) break;
            usleep(10000);
        }
        if (!stopped) FAIL("等待原生调试附加失败，未执行远程代码");
        if (ptrace(PT_DETACH, pid, (caddr_t)1, 0)) FAIL("无法分离原生调试控制：%s", strerror(errno));
        attached = 0;
        if (csops(pid, WeChatCSStatus, &csflags, sizeof(csflags)) || !(csflags & WeChatCSDebugged))
            FAIL("系统未允许执行进程内代码，已取消注入");
    }
    if (mach_vm_allocate(task, &data, data_size, VM_FLAGS_ANYWHERE) != KERN_SUCCESS ||
        mach_vm_allocate(task, &code, page, VM_FLAGS_ANYWHERE) != KERN_SUCCESS ||
        mach_vm_allocate(task, &stack, stack_size, VM_FLAGS_ANYWHERE) != KERN_SUCCESS) FAIL("无法分配微信进程内存");
    context.init_name = data + sizeof(context);
    context.error_name = context.init_name + sizeof(entry_name);
    context.plan_name = context.error_name + sizeof(error_name);
    context.path = context.plan_name + sizeof(plan_name);
    context.worker = code + (wechat_remote_worker - wechat_remote_code_start);
    context.hook_status = -1;
    context.create_result = -1;
    if (write_remote(task, data, &context, sizeof(context)) != KERN_SUCCESS ||
        write_remote(task, context.init_name, entry_name, sizeof(entry_name)) != KERN_SUCCESS ||
        write_remote(task, context.error_name, error_name, sizeof(error_name)) != KERN_SUCCESS ||
        write_remote(task, context.plan_name, plan_name, sizeof(plan_name)) != KERN_SUCCESS ||
        write_remote(task, context.path, dylib, strlen(dylib) + 1) != KERN_SUCCESS ||
        write_remote(task, code, wechat_remote_code_start, code_size) != KERN_SUCCESS) FAIL("无法写入微信进程私有内存");
    kr = mach_vm_protect(task, code, page, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
    if (kr != KERN_SUCCESS) FAIL("系统拒绝执行注入引导代码：%s；未更改系统保护或微信签名", mach_error_string(kr));
    // No existing thread is suspended or hijacked. The bootstrap only creates a
    // real pthread; dyld calls execute there, with valid pthread TLS.
    arm_thread_state64_t state = {0};
    state.__x[0] = data;
    arm_thread_state64_set_pc_fptr(state, (void *)code);
    arm_thread_state64_set_sp(state, stack + stack_size - 16);
    kr = thread_create_running(task, ARM_THREAD_STATE64, (thread_state_t)&state, ARM_THREAD_STATE64_COUNT, &thread);
    if (kr != KERN_SUCCESS) FAIL("创建注入引导线程失败：%s", mach_error_string(kr));
    thread_started = 1;
    double deadline = monotonic_seconds() + 15;
    while (monotonic_seconds() < deadline) {
        if (!read_remote(task, data, &context, sizeof(context))) FAIL("注入过程中微信已退出或远程内存不可读");
        if (context.bootstrap_done && thread != MACH_PORT_NULL) {
            if (thread_terminate(thread) != KERN_SUCCESS) FAIL("无法结束注入引导线程");
            mach_port_deallocate(mach_task_self(), thread);
            thread = MACH_PORT_NULL;
            mach_vm_deallocate(task, stack, stack_size);
            stack = 0;
        }
        if (context.bootstrap_done && context.create_result != 0) FAIL("创建插件 pthread 失败：%d", context.create_result);
        if (context.patch_requested && context.patch_ack == 0) {
            const int applied = apply_patch_plan(task, context.plan_address, error, error_size);
            const int32_t acknowledgement = applied == 1 ? 1 : -1;
            if (write_remote(task, data + offsetof(Context, patch_ack), &acknowledgement, sizeof(acknowledgement)) != KERN_SUCCESS)
                FAIL("无法回传入口写入结果，请重启微信后再试");
            if (applied != 1) goto cleanup; // Keep the precise controller error.
        }
        if (context.worker_done && context.bootstrap_done) {
            switch (context.hook_status) {
                case -10: FAIL("运行中的微信不是已适配的 268602/270353，请退出后重新打开目标版本");
                case -11: FAIL("插件已加载，但 dyld 中未找到微信核心库 wechat.dylib");
                case -12: FAIL("微信核心库的架构或内存镜像信息不符合预期");
                case -13: FAIL("插件已加载，但撤回函数指令与已适配版本不一致（入口、分支、字段或派发桩校验失败）");
                case -14: FAIL("已找到撤回函数及派发桩，但系统拒绝写入进程内 Hook 指针");
                case -16: FAIL("撤回函数出现多个匹配，已停止挂钩，避免使用错误地址");
                case -17: FAIL("入口准备失败：%s", context.error[0] ? context.error : "跳转页或入口指令校验失败");
                case -18: FAIL("入口写入未完成或等待控制进程超时，请重启微信后再试");
            }
            if (context.hook_status != 1) FAIL("插件加载或 Hook 失败（%d）：%s", context.hook_status,
                context.error[0] ? context.error : "当前微信状态或构建不支持；未修改微信文件");
            result = 1;
            goto cleanup;
        }
        usleep(20000);
    }
    FAIL("等待插件响应超时；未终止微信。请退出微信后再试，不要连续重复注入");
cleanup:
    if (attached && ptrace(PT_DETACH, pid, (caddr_t)1, 0)) {
        snprintf(error, error_size, "原生调试分离失败：%s；微信可能仍暂停，请手动退出并重新打开微信", strerror(errno));
    }
    if (thread != MACH_PORT_NULL) {
        kern_return_t terminated = thread_terminate(thread);
        mach_port_deallocate(mach_task_self(), thread);
        if (terminated != KERN_SUCCESS) stack = 0; // May still be in use.
    }
    if (stack) mach_vm_deallocate(task, stack, stack_size);
    // Once a pthread may exist, keep its bootstrap code/context mapped until
    // WeChat exits. Even after worker_done, its return epilogue may still run.
    if (!thread_started) {
        if (data) mach_vm_deallocate(task, data, data_size);
        if (code) mach_vm_deallocate(task, code, page);
    }
    if (task != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), task);
    if (lock_fd >= 0) close(lock_fd);
    return result;
#else
    snprintf(error, error_size, "原生注入仅支持 arm64 控制程序");
    return 0;
#endif
#undef FAIL
}
