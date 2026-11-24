/* Disable LeakSanitizer at build time (SPEC §6.2 item 15); ASan + UBSan stay active.
 * wld's main() leaks the realpath() result on every run. */
int __lsan_is_turned_off(void) { return 1; }
