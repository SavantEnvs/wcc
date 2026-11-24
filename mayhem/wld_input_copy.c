/*
 * File-input wrapper for wld (Mayhem targets wld-sections / wld-segments).
 *
 * wld opens its input O_RDWR and patches it in place through a MAP_SHARED mapping, so it
 * needs a writable file and would otherwise rewrite the fuzzer's own input. This main()
 * copies the last argument (the input, `@@`) to a scratch file under $TMPDIR (fallback
 * /tmp), passes that path to wld's unmodified main() (compiled with -Dmain=wld_original_main),
 * and removes the copy at a normal exit — including wld's own exit() paths.
 *
 * The scratch name is fixed per input path ($TMPDIR/wld-input-<uid>-<fnv1a(input path)>) and
 * is truncated and rewritten on every run, so each run depends only on its input. A crash
 * (ASan/UBSan abort, SEGV) skips the atexit() cleanup, but the next run on the same input
 * path (the fuzzer's current-input file) reuses the same name, so leftovers never pile up:
 * at most one copy exists per input path. (wld realpath()s its argument, so an unlinked
 * file reopened through /proc/self/fd is not an option.)
 */
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int wld_original_main(int argc, char **argv);

static char tmp_path[4096];

static void remove_copy(void)
{
	if (tmp_path[0])
		unlink(tmp_path);
}

static uint64_t fnv1a(const char *s)
{
	uint64_t h = 0xcbf29ce484222325ULL;
	for (; *s; s++) {
		h ^= (unsigned char)*s;
		h *= 0x100000001b3ULL;
	}
	return h;
}

int main(int argc, char **argv)
{
	if (argc < 2)
		return wld_original_main(argc, argv);

	const char *dir = getenv("TMPDIR");
	if (!dir || !*dir)
		dir = "/tmp";
	snprintf(tmp_path, sizeof(tmp_path), "%s/wld-input-%u-%016llx", dir, (unsigned)getuid(),
		 (unsigned long long)fnv1a(argv[argc - 1]));
	int out = open(tmp_path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0600);
	if (out < 0) {
		perror("open copy");
		tmp_path[0] = 0;
		return 1;
	}
	atexit(remove_copy);

	int in = open(argv[argc - 1], O_RDONLY);
	if (in < 0) {
		perror("open input");
		close(out);
		return 1;
	}
	char buf[65536];
	ssize_t n;
	while ((n = read(in, buf, sizeof(buf))) > 0) {
		char *p = buf;
		while (n > 0) {
			ssize_t w = write(out, p, (size_t)n);
			if (w <= 0) {
				perror("write copy");
				return 1;
			}
			p += w;
			n -= w;
		}
	}
	close(in);
	close(out);

	argv[argc - 1] = tmp_path;
	return wld_original_main(argc, argv);
}
