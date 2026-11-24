/* Oracle fixture + seed source: a libc-free shared object whose only dynamic symbols are
 * mayhem_add / mayhem_answer (see nostdlib.map). Its symbol table avoids wcc's renamed
 * ("blacklisted") names and its .data is pointer-sized, so wcc processes it end to end.
 * build.sh: clang -O0 -nostdlib -shared -fPIC -Wl,--version-script=nostdlib.map */
long mayhem_answer[2] = { 42, 7 };

int mayhem_add(int a, int b)
{
	return a + b;
}

void _start(void)
{
	__asm__ volatile("mov $60, %%eax; xor %%edi, %%edi; syscall" ::: "memory");
}
