/* Generated for the koru vendored tree (meson substitutes the three
   numbers into pixman-version.h.in; everything else is verbatim). */
#ifndef PIXMAN_VERSION_H__
#define PIXMAN_VERSION_H__

#ifndef PIXMAN_H__
#  error pixman-version.h must only be included within pixman.h
#endif

#define PIXMAN_VERSION_MAJOR 0
#define PIXMAN_VERSION_MINOR 42
#define PIXMAN_VERSION_MICRO 2

#define PIXMAN_VERSION_STRING "0.42.2"

#define PIXMAN_VERSION_ENCODE(major, minor, micro) (	\
	  ((major) * 10000)				\
	+ ((minor) *   100)				\
	+ ((micro) *     1))

#define PIXMAN_VERSION PIXMAN_VERSION_ENCODE(	\
	PIXMAN_VERSION_MAJOR,			\
	PIXMAN_VERSION_MINOR,			\
	PIXMAN_VERSION_MICRO)

#ifndef PIXMAN_API
# define PIXMAN_API
#endif

#endif /* PIXMAN_VERSION_H__ */
