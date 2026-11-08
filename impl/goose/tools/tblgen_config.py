import re,sys
L='/opt/llvm-project-23.1.5/llvm/include/llvm/Config/'
vals={'LLVM_VERSION_MAJOR':'23','LLVM_VERSION_MINOR':'1','LLVM_VERSION_PATCH':'5','PACKAGE_VERSION':'"23.1.5"',
'LLVM_DEFAULT_TARGET_TRIPLE':'"x86_64-unknown-linux-gnu"','LLVM_HOST_TRIPLE':'"x86_64-unknown-linux-gnu"',
'LLVM_ENABLE_THREADS':'1','LLVM_HAS_ATOMICS':'1','LLVM_ON_UNIX':'1','HAVE_PTHREAD_H':'1','HAVE_UNISTD_H':'1',
'HAVE_SYS_MMAN_H':'1','HAVE_FCNTL_H':'1','HAVE_DLFCN_H':'1','HAVE_SIGNAL_H':'1','HAVE_SYS_STAT_H':'1','HAVE_SYS_TIME_H':'1',
'HAVE_SYS_RESOURCE_H':'1','HAVE_SYS_IOCTL_H':'1','HAVE_TERMIOS_H':'1','HAVE_ERRNO_H':'1','HAVE_GETPAGESIZE':'1',
'HAVE_GETRUSAGE':'1','HAVE_ISATTY':'1','HAVE_FUTIMENS':'1','HAVE_FUTIMES':'1','HAVE_POSIX_FALLOCATE':'1','HAVE_SETENV':'1',
'HAVE_STRERROR_R':'1','HAVE_SYSCONF':'1','HAVE_DLOPEN':'1','HAVE_PTHREAD_GETNAME_NP':'1','HAVE_PTHREAD_SETNAME_NP':'1',
'HAVE_PTHREAD_RWLOCK_INIT':'1','HAVE_PTHREAD_MUTEX_LOCK':'1','HAVE_LINK_H':'1','HAVE_MALLINFO2':'1','HAVE_MALLOC_H':'1',
'HAVE_SBRK':'1','HAVE_DECL_STRERROR_S':'0','HAVE_DECL_ARC4RANDOM':'0','HAVE_DECL_FE_ALL_EXCEPT':'1','HAVE_DECL_FE_INEXACT':'1',
'LTDL_SHLIB_EXT':'".so"','LLVM_PLUGIN_EXT':'".so"','BUG_REPORT_URL':'"x"','PACKAGE_NAME':'"LLVM"','PACKAGE_STRING':'"LLVM 23.1.5"',
'PACKAGE_BUGREPORT':'"x"','PACKAGE_VENDOR':'""','HOST_LINK_VERSION':'""','LLVM_VERSION_INFO':'""',
'LLVM_ENABLE_ABI_BREAKING_CHECKS':'0','LLVM_ENABLE_REVERSE_ITERATION':'0','LLVM_ENABLE_DIA_SDK':'0',
'LLVM_NATIVE_ARCH':'X86','LLVM_HAVE_TFLITE':'0','LLVM_ENABLE_ZLIB':'0','LLVM_ENABLE_ZSTD':'0','LLVM_ENABLE_CURL':'0',
'LLVM_ENABLE_HTTPLIB':'0','LLVM_WITH_Z3':'0','LLVM_ENABLE_LIBXML2':'0','LLVM_BUILD_LLVM_DYLIB':'0','LLVM_BUILD_SHARED_LIBS':'0',
'LLVM_FORCE_USE_OLD_TOOLCHAIN':'0','LLVM_ENABLE_PLUGINS':'0','LLVM_HAS_LOGF128':'0','LLVM_ENABLE_TELEMETRY':'0',
'LLVM_ENABLE_DEBUGLOC_TRACKING_COVERAGE':'0','LLVM_ENABLE_DEBUGLOC_TRACKING_ORIGIN':'0','LLVM_ENABLE_ONDISK_CAS':'0',
'HAVE_UNW_ADD_DYNAMIC_FDE':'0','HAVE_REGISTER_FRAME':'0','HAVE_DEREGISTER_FRAME':'0','HAVE_BACKTRACE':'1','BACKTRACE_HEADER':'<execinfo.h>',
'ENABLE_BACKTRACES':'1','LLVM_ENABLE_CRASH_OVERRIDES':'1','LLVM_GISEL_COV_PREFIX':'""','LLVM_ENABLE_LLVM_EXPORT_ANNOTATIONS':'0',
'LLVM_UNREACHABLE_OPTIMIZE':'1','LLVM_HAVE_LIBXAR':'0','LLVM_SUPPORT_XCODE_SIGNPOSTS':'0','HAVE_PROC_PID_RUSAGE':'0','HAVE_MACH_MACH_H':'0',
'LLVM_ENABLE_PROFCHECK':'0','LLVM_ENABLE_DUMP':'0','LLVM_ENABLE_DEBUGLOC_COVERAGE_TRACKING':'0','LLVM_USE_INTEL_JITEVENTS':'0','LLVM_USE_OPROFILE':'0','LLVM_USE_PERF':'0'}
for f in ['config.h','llvm-config.h','abi-breaking.h','Targets.h']:
    s=open(L+f+'.cmake').read()
    def rep(m):
        n=m.group(2)
        if m.group(1)=='cmakedefine01': return '#define %s %s'%(n, '1' if vals.get(n,'0') not in ('0',) else '0')
        if n in vals and vals[n]!='0': return '#define %s %s'%(n, m.group(3) if m.group(3) and '$' not in m.group(3) and '@' not in m.group(3) else vals[n])
        return '/* #undef %s */'%n
    s=re.sub(r'#(cmakedefine01|cmakedefine)\s+(\w+)(?:[ \t]+(.*))?',rep,s)
    s=re.sub(r'\$\{(\w+)\}',lambda m: vals.get(m.group(1),'0'),s)
    s=re.sub(r'@(\w+)@',lambda m: vals.get(m.group(1),''),s)
    open('inc/llvm/Config/'+f,'w').write(s)
for f in ['AsmParsers.def','AsmPrinters.def','Disassemblers.def','TargetMCAs.def','Targets.def','TargetExegesis.def']:
    s=open(L+f+'.in').read()
    s=re.sub(r'@\w+@','',s)
    open('inc/llvm/Config/'+f,'w').write(s)
