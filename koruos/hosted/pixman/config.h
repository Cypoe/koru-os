// Hand-written for x86_64-linux-musl via zig cc (clang): the SIMD paths
// clang's x86 intrinsics support, no pthreads (the seam has no threads),
// no openmp, no timers.
#define _GNU_SOURCE 1
#define SIZEOF_LONG 8
#define TLS __thread
#define USE_X86_MMX 1
#define USE_SSE2 1
#define USE_SSSE3 1
#define USE_GCC_VECTOR_EXTENSIONS 1
#define TOOLCHAIN_SUPPORTS_ATTRIBUTE_CONSTRUCTOR 1
#define HAVE_BUILTIN_CLZ 1
#define HAVE_BUILTIN_EXPECT 1
#define HAVE_CLZ 1
#define PACKAGE "pixman"
