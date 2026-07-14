/* longdouble-const.c — the minimal root-cause reproducer.
 *
 * No libm, no printf-of-long-double, no libc math: this exercises ONLY the
 * compiler's emission of a long-double *constant*. tcc's riscv64 backend in
 * the bootstrap-chain vintage (upstream mob 8cd21e91, 2024-06) emits it
 * corrupted; upstream mob >= 923fba83 ("general: long double issues",
 * "init_putv(): improve long double cross constants", 2026-05) emits it
 * correctly.
 *
 * Exit 0 = correct, 2 = constant came out all-zero, 3 = constant has the
 * wrong value. Compile with a riscv64 tcc, run under qemu-user (or on real
 * RISC-V hardware).
 */
int main(void)
{
    long double x = 0.30102999566398119521L;   /* log10(2) */
    double d = (double) x;
    unsigned char *p = (unsigned char *) &x;
    int all_zero = 1, i;

    for (i = 0; i < (int) sizeof x; i++)
        if (p[i]) all_zero = 0;

    if (all_zero) return 2;
    if (!(d > 0.30 && d < 0.31)) return 3;
    return 0;
}
