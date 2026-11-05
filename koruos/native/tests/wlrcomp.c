// wlrcomp.c — wlroots 0.16 on the koru seam: a REAL compositor library
// running nested as a client of our libwayland-server wlserver.
//
// The shape is tinywl's, trimmed to the honest rung: the wayland
// backend connects to /wayland-1 as an ordinary shm/xdg client, the
// pixman renderer draws the scene, wlr_shm allocates buffers in
// /dev/shm, and this binary hosts its own display on /wayland-2 for
// downstream clients — three protocol hops from window pixels to
// virtio-gpu scanout.
//
// What the seam answers here: epoll+eventfd (both wl_displays),
// timerfd (wlr_output frame scheduling, seat repeat), /dev/shm named
// objects (the allocator's shm pools, wlr_keyboard's RW+RO keymap
// pair), SO_PEERCRED, pathname sockets both directions, SCM_RIGHTS,
// xkbcommon parsing the upstream keymap, and the whole libwayland
// client+server surface — every refusal names the missing class.

#define _POSIX_C_SOURCE 200112L
#include <assert.h>
#include <getopt.h>
#include <poll.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>
#include <wayland-server-core.h>
#include <wlr/backend.h>
#include <wlr/backend/wayland.h>
#include <wlr/render/allocator.h>
#include <wlr/render/wlr_renderer.h>
#include <wlr/types/wlr_compositor.h>
#include <wlr/types/wlr_cursor.h>
#include <wlr/types/wlr_data_device.h>
#include <wlr/types/wlr_input_device.h>
#include <wlr/types/wlr_keyboard.h>
#include <wlr/types/wlr_output.h>
#include <wlr/types/wlr_output_layout.h>
#include <wlr/types/wlr_pointer.h>
#include <wlr/types/wlr_scene.h>
#include <wlr/types/wlr_seat.h>
#include <wlr/types/wlr_subcompositor.h>
#include <wlr/types/wlr_xdg_shell.h>
#include <wlr/util/log.h>
#include <xkbcommon/xkbcommon.h>

struct wlrcomp_server {
	struct wl_display *wl_display;
	struct wlr_backend *backend;
	struct wlr_renderer *renderer;
	struct wlr_allocator *allocator;
	struct wlr_scene *scene;
	int nclients;
	bool had_client;

	struct wlr_xdg_shell *xdg_shell;
	struct wl_listener new_xdg_surface;
	struct wl_list views;

	struct wlr_cursor *cursor;
	struct wl_listener cursor_motion;
	struct wl_listener cursor_motion_absolute;
	struct wl_listener cursor_button;
	struct wl_listener cursor_axis;
	struct wl_listener cursor_frame;

	struct wlr_seat *seat;
	struct wl_listener new_input;
	struct wl_listener request_cursor;
	struct wl_listener request_set_selection;
	struct wl_list keyboards;

	struct wlr_output_layout *output_layout;
	struct wl_list outputs;
	struct wl_listener new_output;

	struct wl_listener client_created;
};

struct wlrcomp_output {
	struct wl_list link;
	struct wlrcomp_server *server;
	struct wlr_output *wlr_output;
	struct wl_listener frame;
	struct wl_listener destroy;
};

struct wlrcomp_keyboard {
	struct wl_list link;
	struct wlrcomp_server *server;
	struct wlr_keyboard *wlr_keyboard;
	struct wl_listener modifiers;
	struct wl_listener key;
};

struct wlrcomp_view {
	struct wl_list link;
	struct wlrcomp_server *server;
	struct wlr_xdg_toplevel *xdg_toplevel;
	struct wlr_scene_tree *scene_tree;
	struct wl_listener map;
	struct wl_listener unmap;
	struct wl_listener destroy;
};

static void focus_view(struct wlrcomp_view *view, struct wlr_surface *surface) {
	if (view == NULL) {
		return;
	}
	struct wlrcomp_server *server = view->server;
	struct wlr_seat *seat = server->seat;
	struct wlr_surface *prev_surface = seat->keyboard_state.focused_surface;
	if (prev_surface == surface) {
		return;
	}
	if (prev_surface) {
		struct wlr_xdg_surface *previous = wlr_xdg_surface_from_wlr_surface(
			prev_surface);
		assert(previous->role == WLR_XDG_SURFACE_ROLE_TOPLEVEL);
		wlr_xdg_toplevel_set_activated(previous->toplevel, false);
	}
	struct wlr_keyboard *keyboard = wlr_seat_get_keyboard(seat);
	wlr_scene_node_raise_to_top(&view->scene_tree->node);
	wl_list_remove(&view->link);
	wl_list_insert(&server->views, &view->link);
	wlr_xdg_toplevel_set_activated(view->xdg_toplevel, true);
	if (keyboard != NULL) {
		wlr_seat_keyboard_notify_enter(seat, view->xdg_toplevel->base->surface,
			keyboard->keycodes, keyboard->num_keycodes, &keyboard->modifiers);
	}
}

static void keyboard_handle_modifiers(struct wl_listener *listener, void *data) {
	struct wlrcomp_keyboard *kb =
		wl_container_of(listener, kb, modifiers);
	wlr_seat_set_keyboard(kb->server->seat, kb->wlr_keyboard);
	wlr_seat_keyboard_notify_modifiers(kb->server->seat,
		&kb->wlr_keyboard->modifiers);
}

static void keyboard_handle_key(struct wl_listener *listener, void *data) {
	struct wlrcomp_keyboard *kb =
		wl_container_of(listener, kb, key);
	struct wlr_keyboard_key_event *event = data;
	struct wlr_seat *seat = kb->server->seat;

	// The honest rung has no compositor keybindings — every key goes to
	// the focused client, unfiltered.
	uint32_t keycode = event->keycode + 8;
	const xkb_keysym_t *syms;
	int nsyms = xkb_state_key_get_syms(
		kb->wlr_keyboard->xkb_state, keycode, &syms);
	printf("WLRC key=%u nsyms=%d state=%d\n", event->keycode, nsyms,
		event->state);
	wlr_seat_set_keyboard(seat, kb->wlr_keyboard);
	wlr_seat_keyboard_notify_key(seat, event->time_msec,
		event->keycode, event->state);
}

static void server_new_input(struct wl_listener *listener, void *data) {
	struct wlrcomp_server *server =
		wl_container_of(listener, server, new_input);
	struct wlr_input_device *device = data;
	switch (device->type) {
	case WLR_INPUT_DEVICE_KEYBOARD:;
		struct wlr_keyboard *wlr_keyboard = wlr_keyboard_from_input_device(device);
		struct wlrcomp_keyboard *kb =
			calloc(1, sizeof(struct wlrcomp_keyboard));
		kb->server = server;
		kb->wlr_keyboard = wlr_keyboard;

		struct xkb_context *context = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
		struct xkb_keymap *keymap =
			xkb_keymap_new_from_names(context, NULL, XKB_KEYMAP_COMPILE_NO_FLAGS);
		if (keymap != NULL) {
			wlr_keyboard_set_keymap(wlr_keyboard, keymap);
			xkb_keymap_unref(keymap);
		}
		xkb_context_unref(context);
		wlr_keyboard_set_repeat_info(wlr_keyboard, 25, 600);

		kb->modifiers.notify = keyboard_handle_modifiers;
		wl_signal_add(&wlr_keyboard->events.modifiers, &kb->modifiers);
		kb->key.notify = keyboard_handle_key;
		wl_signal_add(&wlr_keyboard->events.key, &kb->key);
		wl_list_insert(&server->keyboards, &kb->link);

		wlr_seat_set_keyboard(server->seat, wlr_keyboard);
		printf("WLRC new-input: keyboard (keymap parsed via xkbcommon)\n");
		break;
	case WLR_INPUT_DEVICE_POINTER:
		wlr_cursor_attach_input_device(server->cursor, device);
		printf("WLRC new-input: pointer\n");
		break;
	default:
		break;
	}
	uint32_t caps = WL_SEAT_CAPABILITY_POINTER;
	if (!wl_list_empty(&server->keyboards)) {
		caps |= WL_SEAT_CAPABILITY_KEYBOARD;
	}
	wlr_seat_set_capabilities(server->seat, caps);
}

static void seat_request_cursor(struct wl_listener *listener, void *data) {
	// No xcursor theme files exist on this arm — the client-provided
	// cursor surface is still honored through wlr_cursor's own path.
	struct wlrcomp_server *server =
		wl_container_of(listener, server, request_cursor);
	struct wlr_seat_pointer_request_set_cursor_event *event = data;
	struct wlr_seat_client *focused_client =
		server->seat->pointer_state.focused_client;
	if (focused_client == event->seat_client) {
		wlr_cursor_set_surface(server->cursor, event->surface,
			event->hotspot_x, event->hotspot_y);
	}
}

static void seat_request_set_selection(struct wl_listener *listener, void *data) {
	struct wlrcomp_server *server =
		wl_container_of(listener, server, request_set_selection);
	struct wlr_seat_request_set_selection_event *event = data;
	wlr_seat_set_selection(server->seat, event->source, event->serial);
}

static struct wlrcomp_view *view_at(struct wlrcomp_server *server,
		double lx, double ly, struct wlr_surface **surface,
		double *sx, double *sy) {
	struct wlr_scene_node *node = wlr_scene_node_at(
		&server->scene->tree.node, lx, ly, sx, sy);
	if (node == NULL || node->type != WLR_SCENE_NODE_BUFFER) {
		return NULL;
	}
	struct wlr_scene_buffer *scene_buffer = wlr_scene_buffer_from_node(node);
	struct wlr_scene_surface *scene_surface =
		wlr_scene_surface_from_buffer(scene_buffer);
	if (!scene_surface) {
		return NULL;
	}
	*surface = scene_surface->surface;
	struct wlr_scene_tree *tree = node->parent;
	while (tree != NULL && tree->node.data == NULL) {
		tree = tree->node.parent;
	}
	return tree == NULL ? NULL : tree->node.data;
}

static void process_cursor_motion(struct wlrcomp_server *server, uint32_t time) {
	double sx, sy;
	struct wlr_surface *surface = NULL;
	struct wlrcomp_view *view = view_at(server,
		server->cursor->x, server->cursor->y, &surface, &sx, &sy);
	if (!view) {
		wlr_seat_pointer_clear_focus(server->seat);
		return;
	}
	wlr_seat_pointer_notify_enter(server->seat, surface, sx, sy);
	wlr_seat_pointer_notify_motion(server->seat, time, sx, sy);
}

static void server_cursor_motion(struct wl_listener *listener, void *data) {
	struct wlrcomp_server *server =
		wl_container_of(listener, server, cursor_motion);
	struct wlr_pointer_motion_event *event = data;
	wlr_cursor_move(server->cursor, &event->pointer->base,
		event->delta_x, event->delta_y);
	process_cursor_motion(server, event->time_msec);
}

static void server_cursor_motion_absolute(
		struct wl_listener *listener, void *data) {
	struct wlrcomp_server *server =
		wl_container_of(listener, server, cursor_motion_absolute);
	struct wlr_pointer_motion_absolute_event *event = data;
	wlr_cursor_warp_absolute(server->cursor, &event->pointer->base,
		event->x, event->y);
	process_cursor_motion(server, event->time_msec);
}

static void server_cursor_button(struct wl_listener *listener, void *data) {
	struct wlrcomp_server *server =
		wl_container_of(listener, server, cursor_button);
	struct wlr_pointer_button_event *event = data;
	wlr_seat_pointer_notify_button(server->seat,
		event->time_msec, event->button, event->state);
	double sx, sy;
	struct wlr_surface *surface = NULL;
	struct wlrcomp_view *view = view_at(server,
		server->cursor->x, server->cursor->y, &surface, &sx, &sy);
	if (event->state == WLR_BUTTON_RELEASED) {
		return;
	}
	if (view) {
		focus_view(view, surface);
		printf("WLRC focus view=%p\n", (void *)view);
	}
}

static void server_cursor_axis(struct wl_listener *listener, void *data) {
	struct wlrcomp_server *server =
		wl_container_of(listener, server, cursor_axis);
	struct wlr_pointer_axis_event *event = data;
	wlr_seat_pointer_notify_axis(server->seat,
		event->time_msec, event->orientation, event->delta,
		event->delta_discrete, event->source);
}

static void server_cursor_frame(struct wl_listener *listener, void *data) {
	struct wlrcomp_server *server =
		wl_container_of(listener, server, cursor_frame);
	wlr_seat_pointer_notify_frame(server->seat);
}

static void output_frame(struct wl_listener *listener, void *data) {
	struct wlrcomp_output *output = wl_container_of(listener, output, frame);
	struct wlr_scene *scene = output->server->scene;
	struct wlr_scene_output *scene_output = wlr_scene_get_scene_output(
		scene, output->wlr_output);
	wlr_scene_output_commit(scene_output);
	struct timespec now;
	clock_gettime(CLOCK_MONOTONIC, &now);
	wlr_scene_output_send_frame_done(scene_output, &now);
}

static void output_destroy(struct wl_listener *listener, void *data) {
	struct wlrcomp_output *output = wl_container_of(listener, output, destroy);
	wl_list_remove(&output->frame.link);
	wl_list_remove(&output->destroy.link);
	wl_list_remove(&output->link);
	free(output);
}

static void server_new_output(struct wl_listener *listener, void *data) {
	struct wlrcomp_server *server =
		wl_container_of(listener, server, new_output);
	struct wlr_output *wlr_output = data;

	wlr_output_init_render(wlr_output, server->allocator, server->renderer);

	if (!wl_list_empty(&wlr_output->modes)) {
		struct wlr_output_mode *mode = wlr_output_preferred_mode(wlr_output);
		wlr_output_set_mode(wlr_output, mode);
	}
	wlr_output_enable(wlr_output, true);
	if (!wlr_output_commit(wlr_output)) {
		return;
	}

	struct wlrcomp_output *output =
		calloc(1, sizeof(struct wlrcomp_output));
	output->wlr_output = wlr_output;
	output->server = server;
	output->frame.notify = output_frame;
	wl_signal_add(&wlr_output->events.frame, &output->frame);
	output->destroy.notify = output_destroy;
	wl_signal_add(&wlr_output->events.destroy, &output->destroy);
	wl_list_insert(&server->outputs, &output->link);

	wlr_output_layout_add_auto(server->output_layout, wlr_output);
	printf("WLRC new-output %ux%u\n",
		wlr_output->width, wlr_output->height);
}

static void xdg_toplevel_map(struct wl_listener *listener, void *data) {
	struct wlrcomp_view *view = wl_container_of(listener, view, map);
	wl_list_insert(&view->server->views, &view->link);
	focus_view(view, view->xdg_toplevel->base->surface);
	printf("WLRC view mapped\n");
}

static void xdg_toplevel_unmap(struct wl_listener *listener, void *data) {
	struct wlrcomp_view *view = wl_container_of(listener, view, unmap);
	wl_list_remove(&view->link);
}

static void xdg_toplevel_destroy(struct wl_listener *listener, void *data) {
	struct wlrcomp_view *view = wl_container_of(listener, view, destroy);
	wl_list_remove(&view->map.link);
	wl_list_remove(&view->unmap.link);
	wl_list_remove(&view->destroy.link);
	free(view);
}

static void server_new_xdg_surface(struct wl_listener *listener, void *data) {
	struct wlrcomp_server *server =
		wl_container_of(listener, server, new_xdg_surface);
	struct wlr_xdg_surface *xdg_surface = data;

	if (xdg_surface->role == WLR_XDG_SURFACE_ROLE_POPUP) {
		struct wlr_xdg_surface *parent = wlr_xdg_surface_from_wlr_surface(
			xdg_surface->popup->parent);
		struct wlr_scene_tree *parent_tree = parent->data;
		xdg_surface->data = wlr_scene_xdg_surface_create(
			parent_tree, xdg_surface);
		return;
	}
	assert(xdg_surface->role == WLR_XDG_SURFACE_ROLE_TOPLEVEL);

	struct wlrcomp_view *view = calloc(1, sizeof(struct wlrcomp_view));
	view->server = server;
	view->xdg_toplevel = xdg_surface->toplevel;
	view->scene_tree = wlr_scene_xdg_surface_create(
		&view->server->scene->tree, view->xdg_toplevel->base);
	view->scene_tree->node.data = view;
	xdg_surface->data = view->scene_tree;

	view->map.notify = xdg_toplevel_map;
	wl_signal_add(&xdg_surface->events.map, &view->map);
	view->unmap.notify = xdg_toplevel_unmap;
	wl_signal_add(&xdg_surface->events.unmap, &view->unmap);
	view->destroy.notify = xdg_toplevel_destroy;
	wl_signal_add(&xdg_surface->events.destroy, &view->destroy);

	wlr_xdg_toplevel_set_size(xdg_surface->toplevel, 200, 150);
	printf("WLRC new xdg toplevel\n");
}

struct wlrcomp_client {
	struct wlrcomp_server *server;
	struct wl_listener destroy;
};

// The same quiescence policy wlserver runs: once at least one client
// has come and ALL have gone, the nested compositor's work is done —
// terminate pokes the display's terminate eventfd so wl_display_run
// returns and the chain can unwind bottom-up.
static void client_destroy(struct wl_listener *listener, void *data) {
	struct wlrcomp_client *cli =
		wl_container_of(listener, cli, destroy);
	struct wlrcomp_server *server = cli->server;
	free(cli);
	server->nclients--;
	if (server->had_client && server->nclients == 0) {
		printf("WLRC quiescent — terminating\n");
		wl_display_terminate(server->wl_display);
	}
}

static void client_created(struct wl_listener *listener, void *data) {
	struct wlrcomp_server *server =
		wl_container_of(listener, server, client_created);
	struct wl_client *client = data;
	struct wlrcomp_client *cli = calloc(1, sizeof(*cli));
	cli->server = server;
	cli->destroy.notify = client_destroy;
	wl_client_add_destroy_listener(client, &cli->destroy);
	server->nclients++;
	server->had_client = true;
	printf("WLRC client +1 n=%d\n", server->nclients);
}

int main(int argc, char *argv[]) {
	wlr_log_init(WLR_INFO, NULL);

	struct wlrcomp_server server = {0};
	server.wl_display = wl_display_create();
	assert(server.wl_display);

	// Explicit: the nested wayland backend — a real client of our
	// wlserver on /wayland-1 (WAYLAND_DISPLAY absolute-path trick).
	// The vendored xkeyboard-config tree rides the ext2 image at /xkb —
	// libxkbcommon's compiled-in default points nowhere on this arm.
	setenv("XKB_CONFIG_ROOT", "/xkb", 1);
	printf("WLRC xkbroot=%s\n", getenv("XKB_CONFIG_ROOT"));
	setenv("WAYLAND_DISPLAY", "/wayland-1", 1);
	// wlserver may still be binding its socket — poll(NULL,0,ms) is the
	// seam's honest sleep (no nanosleep nr on this arm).
	for (int tries = 0; tries < 200; tries++) {
		server.backend = wlr_wl_backend_create(server.wl_display, NULL);
		if (server.backend != NULL) {
			break;
		}
		poll(NULL, 0, 50);
	}
	if (server.backend == NULL) {
		wlr_log(WLR_ERROR, "WLRC FAIL backend");
		return 1;
	}
	wlr_wl_output_create(server.backend);

	server.renderer = wlr_renderer_autocreate(server.backend);
	if (server.renderer == NULL) {
		wlr_log(WLR_ERROR, "WLRC FAIL renderer");
		return 1;
	}
	wlr_renderer_init_wl_display(server.renderer, server.wl_display);

	server.allocator = wlr_allocator_autocreate(server.backend,
		server.renderer);
	if (server.allocator == NULL) {
		wlr_log(WLR_ERROR, "WLRC FAIL allocator");
		return 1;
	}

	wlr_compositor_create(server.wl_display, server.renderer);
	wlr_subcompositor_create(server.wl_display);
	wlr_data_device_manager_create(server.wl_display);

	server.output_layout = wlr_output_layout_create();

	wl_list_init(&server.outputs);
	server.new_output.notify = server_new_output;
	wl_signal_add(&server.backend->events.new_output, &server.new_output);

	server.scene = wlr_scene_create();
	wlr_scene_attach_output_layout(server.scene, server.output_layout);

	// The desktop's own pixel: a solid rect guarantees the pixman
	// renderer emits something the pixel oracle can read even with
	// zero downstream clients attached.
	float bg[4] = { 0.1f, 0.5f, 0.35f, 1.0f };
	wlr_scene_rect_create(&server.scene->tree, 1280, 720, bg);

	wl_list_init(&server.views);
	server.xdg_shell = wlr_xdg_shell_create(server.wl_display, 3);
	server.new_xdg_surface.notify = server_new_xdg_surface;
	wl_signal_add(&server.xdg_shell->events.new_surface,
		&server.new_xdg_surface);

	server.cursor = wlr_cursor_create();
	wlr_cursor_attach_output_layout(server.cursor, server.output_layout);

	server.cursor_motion.notify = server_cursor_motion;
	wl_signal_add(&server.cursor->events.motion, &server.cursor_motion);
	server.cursor_motion_absolute.notify = server_cursor_motion_absolute;
	wl_signal_add(&server.cursor->events.motion_absolute,
		&server.cursor_motion_absolute);
	server.cursor_button.notify = server_cursor_button;
	wl_signal_add(&server.cursor->events.button, &server.cursor_button);
	server.cursor_axis.notify = server_cursor_axis;
	wl_signal_add(&server.cursor->events.axis, &server.cursor_axis);
	server.cursor_frame.notify = server_cursor_frame;
	wl_signal_add(&server.cursor->events.frame, &server.cursor_frame);

	wl_list_init(&server.keyboards);
	server.new_input.notify = server_new_input;
	wl_signal_add(&server.backend->events.new_input, &server.new_input);
	server.seat = wlr_seat_create(server.wl_display, "seat0");
	server.request_cursor.notify = seat_request_cursor;
	wl_signal_add(&server.seat->events.request_set_cursor,
		&server.request_cursor);
	server.request_set_selection.notify = seat_request_set_selection;
	wl_signal_add(&server.seat->events.request_set_selection,
		&server.request_set_selection);

	// Absolute socket name — no XDG_RUNTIME_DIR on this arm.
	if (wl_display_add_socket(server.wl_display, "/wayland-2") != 0) {
		wlr_log(WLR_ERROR, "WLRC FAIL socket");
		wlr_backend_destroy(server.backend);
		return 1;
	}
	setenv("WAYLAND_DISPLAY", "wayland-2", 1);

	server.client_created.notify = client_created;
	wl_display_add_client_created_listener(server.wl_display,
		&server.client_created);

	if (!wlr_backend_start(server.backend)) {
		wlr_log(WLR_ERROR, "WLRC FAIL backend start");
		wlr_backend_destroy(server.backend);
		wl_display_destroy(server.wl_display);
		return 1;
	}

	printf("WLRC up: backend=wayland renderer=pixman sock=/wayland-2\n");
	fflush(stdout);
	wl_display_run(server.wl_display);

	wl_display_destroy_clients(server.wl_display);
	wl_display_destroy(server.wl_display);
	return 0;
}
