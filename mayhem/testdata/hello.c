/* Oracle fixture for mayhem/test.sh: a small dynamically linked program whose exported
 * functions and data have known names/values. build.sh compiles it (PIE and non-PIE). */
#include <stdio.h>
#include <stdlib.h>

int mayhem_answer = 42;

int mayhem_add(int a, int b)
{
	return a + b;
}

int main(int argc, char **argv)
{
	(void)argv;
	fprintf(stdout, "sum=%d answer=%d\n", mayhem_add(argc, 2), mayhem_answer);
	return getenv("MAYHEM_FIXTURE_FAIL") ? 1 : 0;
}
