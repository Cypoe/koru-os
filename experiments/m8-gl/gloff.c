/* SPDX-License-Identifier: BSD-3-Clause */
/*
 * koru-os M8a probe: offscreen GLES2 through EGL on the Mesa surfaceless platform
 * (no window system, no DRM device). Same binary on koru-os and on the Linux oracle.
 * Renders two frames into a 256x256 RGBA8 FBO: frame 0 clears to (0.1,0.2,0.3) and draws
 * one RGB-interpolated triangle; frame 1 rotates it by 90 degrees. Prints the GL strings,
 * an FNV-1a 64 hash of each frame's pixels, and probe pixels, then "gloff: done, exit 0".
 */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>
#include <fcntl.h>
#include <errno.h>
#include <gbm.h>

#define W 256
#define H 256
static unsigned char px[W * H * 4];

static const char *vs =
	"attribute vec2 p; attribute vec3 c; uniform float a; varying vec3 v;\n"
	"void main() { float s = sin(a), k = cos(a);\n"
	"  gl_Position = vec4(k * p.x - s * p.y, s * p.x + k * p.y, 0.0, 1.0); v = c; }\n";
static const char *fs =
	"precision mediump float; varying vec3 v;\n"
	"void main() { gl_FragColor = vec4(v, 1.0); }\n";

static GLuint sh(GLenum t, const char *src)
{
	GLuint s = glCreateShader(t);
	GLint ok = 0;
	char log[512];

	glShaderSource(s, 1, &src, NULL);
	glCompileShader(s);
	glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
	if (!ok) { glGetShaderInfoLog(s, sizeof(log), NULL, log); printf("gloff: shader: %s\n", log); exit(3); }
	return s;
}

static uint64_t fnv(const unsigned char *b, size_t n)
{
	uint64_t h = 0xcbf29ce484222325ULL;

	for (size_t i = 0; i < n; i++) { h ^= b[i]; h *= 0x100000001b3ULL; }
	return h;
}

int main(int argc, char **argv)
{
	PFNEGLGETPLATFORMDISPLAYEXTPROC gpd;
	EGLint maj, min, n;
	EGLConfig cfg;
	EGLDisplay d;
	EGLContext ctx;
	GLuint prog, fbo, rb, vbo;
	/* FBO rendering only: no surface type needed (GBM offers window configs only) */
	const EGLint ca[] = { EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT, EGL_SURFACE_TYPE, EGL_DONT_CARE, EGL_NONE };
	const EGLint xa[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
	const float vtx[] = { -0.8f, -0.7f, 1, 0, 0,  0.8f, -0.7f, 0, 1, 0,  0.0f, 0.8f, 0, 0, 1 };
	const int probes[][2] = { { 0, 0 }, { 128, 128 }, { 128, 60 }, { 60, 40 }, { 200, 40 }, { 255, 255 } };

	setvbuf(stdout, NULL, _IOLBF, 0);
	printf("gloff: client extensions: %s\n", eglQueryString(EGL_NO_DISPLAY, EGL_EXTENSIONS));
	gpd = (PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress("eglGetPlatformDisplayEXT");
	if (!gpd) { printf("gloff: no eglGetPlatformDisplayEXT\n"); return 2; }
	if (argc > 1) {
		int fd = open(argv[1], O_RDWR | O_CLOEXEC);
		struct gbm_device *g;

		if (fd < 0) { printf("gloff: open %s errno %d\n", argv[1], errno); return 2; }
		g = gbm_create_device(fd);
		if (!g) { printf("gloff: gbm_create_device failed\n"); return 2; }
		printf("gloff: platform gbm on %s, backend %s\n", argv[1], gbm_device_get_backend_name(g));
		d = gpd(EGL_PLATFORM_GBM_MESA, g, NULL);
	} else {
		printf("gloff: platform surfaceless\n");
		d = gpd(EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY, NULL);
	}
	if (d == EGL_NO_DISPLAY || !eglInitialize(d, &maj, &min)) { printf("gloff: eglInitialize failed 0x%x\n", eglGetError()); return 2; }
	printf("gloff: EGL %d.%d vendor %s\n", maj, min, eglQueryString(d, EGL_VENDOR));
	if (!eglChooseConfig(d, ca, &cfg, 1, &n) || n < 1) { printf("gloff: no config 0x%x\n", eglGetError()); return 2; }
	eglBindAPI(EGL_OPENGL_ES_API);
	ctx = eglCreateContext(d, cfg, EGL_NO_CONTEXT, xa);
	if (ctx == EGL_NO_CONTEXT || !eglMakeCurrent(d, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx)) { printf("gloff: context failed 0x%x\n", eglGetError()); return 2; }
	printf("gloff: GL_RENDERER %s\n", glGetString(GL_RENDERER));
	printf("gloff: GL_VERSION %s\n", glGetString(GL_VERSION));

	glGenFramebuffers(1, &fbo); glBindFramebuffer(GL_FRAMEBUFFER, fbo);
	glGenRenderbuffers(1, &rb); glBindRenderbuffer(GL_RENDERBUFFER, rb);
	glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8_OES, W, H);
	glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, rb);
	printf("gloff: FBO status 0x%x\n", glCheckFramebufferStatus(GL_FRAMEBUFFER));
	prog = glCreateProgram();
	glAttachShader(prog, sh(GL_VERTEX_SHADER, vs)); glAttachShader(prog, sh(GL_FRAGMENT_SHADER, fs));
	glBindAttribLocation(prog, 0, "p"); glBindAttribLocation(prog, 1, "c");
	glLinkProgram(prog); glUseProgram(prog);
	glGenBuffers(1, &vbo); glBindBuffer(GL_ARRAY_BUFFER, vbo);
	glBufferData(GL_ARRAY_BUFFER, sizeof(vtx), vtx, GL_STATIC_DRAW);
	glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 20, (void *)0);
	glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, 20, (void *)8);
	glEnableVertexAttribArray(0); glEnableVertexAttribArray(1);
	glViewport(0, 0, W, H);
	for (int f = 0; f < 2; f++) {
		glClearColor(0.1f, 0.2f, 0.3f, 1.0f);
		glClear(GL_COLOR_BUFFER_BIT);
		glUniform1f(glGetUniformLocation(prog, "a"), f * 1.5707963f);
		glDrawArrays(GL_TRIANGLES, 0, 3);
		glFinish();
		memset(px, 0, sizeof(px));
		glReadPixels(0, 0, W, H, GL_RGBA, GL_UNSIGNED_BYTE, px);
		printf("gloff: frame %d glError 0x%x fnv1a64 %016llx\n", f, glGetError(), (unsigned long long)fnv(px, sizeof(px)));
		for (unsigned i = 0; i < sizeof(probes) / sizeof(probes[0]); i++) {
			unsigned char *p = &px[(probes[i][1] * W + probes[i][0]) * 4];
			printf("gloff: frame %d px %d,%d = %d %d %d %d\n", f, probes[i][0], probes[i][1], p[0], p[1], p[2], p[3]);
		}
	}
	eglMakeCurrent(d, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
	eglDestroyContext(d, ctx);
	eglTerminate(d);
	printf("gloff: done, exit 0\n");
	return 0;
}
