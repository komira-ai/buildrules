/* libprobe_sys.a: the native library of the package probe_sys. It calls the one of base_sys, so it needs libbase_sys.a. */
int base_sys_value(void);

int probe_sys_answer(void) { return base_sys_value() + 243; }
