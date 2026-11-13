// Closed compat layer for rootfses whose libstdc++ predates the symbol the
// official payload imports. musl binds by bare name and the payload carries no
// symbol versions, so one missing strong import is enough to abort the load:
//
//   Error relocating .../qoderclicn: _ZSt21__glibcxx_assert_failPKciS0_S0_: symbol not found
//
// Every name here is a libstdc++ assertion/terminate path that only exists in
// GCC >= 12. They never return, so a trap is the correct body and the shim
// needs no libc at all - hence no DT_NEEDED, no interpreter, and no dependence
// on the device's C++ runtime.
//
// Keep this list to symbols that must not continue execution; a stub for a
// symbol the device already implements would shadow the real one.

extern "C" {

// Exported even under -fvisibility=hidden: this name is the whole contract.
void __attribute__((noreturn, visibility("default"))) _ZSt21__glibcxx_assert_failPKciS0_S0_(
    const char *file, int line, const char *func, const char *msg) {
    (void)file;
    (void)line;
    (void)func;
    (void)msg;
    __builtin_trap();
}

}
