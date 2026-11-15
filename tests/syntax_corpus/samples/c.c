/* A C translation unit: preprocessor, typedef ambiguity, declarators. Ünïcode. */
#include <stdio.h>
#include "local.h"
#define MAX(a, b) ((a) > (b) ? (a) : (b))
#define STR(x) #x
#ifdef DEBUG
#  define LOG(...) fprintf(stderr, __VA_ARGS__)
#else
#  define LOG(...) ((void)0)
#endif

typedef struct node {
    int value;
    struct node *next;
} node_t;

typedef int (*callback_t)(void *context, const char *name);

static const char *names[] = {"alpha", "βeta", "gamma", NULL};

enum color { RED, GREEN = 4, BLUE };

static int count(node_t *list) {
    int total = 0;
    for (node_t *it = list; it; it = it->next) total += it->value;
    return total;
}

int apply(callback_t fn, void *context) {
    int result = 0;
    for (size_t i = 0; names[i] != NULL; i++) {
        result = MAX(result, fn(context, names[i]));
        if (result < 0) goto done;
    }
done:
    LOG("result %d\n", result);
    return result;
}

int main(int argc, char **argv) {
    node_t b = {.value = 2, .next = NULL}, a = {1, &b};
    unsigned long mask = 0xFFul << 3;
    char c = '\'';
    float f = 1.5e-3f;
    switch (argc) {
    case 0: break;
    default: printf("%s %lu %c %f\n", argv[0], mask, c, f);
    }
    return count(&a) * (int)sizeof(node_t);
}
