#include <stdio.h>
#include <math.h>
int main(void) {
    int i;
    for (i = 1; i <= 4; i++)
        printf("log10(%d) = %f  (int)(1+log10(%d)) = %d\n",
               i, log10(i), i, (int)(1 + log10(i)));
    return 0;
}
