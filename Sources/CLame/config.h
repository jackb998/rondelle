/* Hand-written configuration for building libmp3lame (encoder only) on macOS with SwiftPM,
 * in place of the one `configure` would generate. No decoder, no frame analyser, no assembly. */
#ifndef LAME_CONFIG_H
#define LAME_CONFIG_H

#define STDC_HEADERS 1
#define HAVE_ERRNO_H 1
#define HAVE_FCNTL_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_LIMITS_H 1
#define HAVE_STDINT_H 1
#define HAVE_STDIO_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRINGS_H 1
#define HAVE_STRING_H 1
#define HAVE_SYS_STAT_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_UNISTD_H 1

#define SIZEOF_SHORT 2
#define SIZEOF_INT 4
#define SIZEOF_LONG 8
#define SIZEOF_LONG_LONG 8
#define SIZEOF_FLOAT 4
#define SIZEOF_DOUBLE 8

#define HAVE_INT8_T 1
#define HAVE_INT16_T 1
#define HAVE_INT32_T 1
#define HAVE_INT64_T 1
#define HAVE_UINT8_T 1
#define HAVE_UINT16_T 1
#define HAVE_UINT32_T 1
#define HAVE_UINT64_T 1

#define LAME_LIBRARY_BUILD 1
/* No frame analyser (used only by the mp3x tool). */
#define NOANALYSIS 1

/* What configure adds when the system lacks these names (macOS does). */
typedef float ieee754_float32_t;
typedef double ieee754_float64_t;

#endif
