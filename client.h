/*
 * Attempt to consolidate unavoidable suck into one file, away from dwl.c.  This
 * file is not meant to be pretty.  We use a .h file with static inline
 * functions instead of a separate .c module, or function pointers like sway, so
 * that they will simply compile out if the chosen #defines leave them unused.
 */

/* Leave these functions first; they're used in the others */
extern struct wlr_surface *client_surface(Client *c);

extern int toplevel_from_wlr_surface(struct wlr_surface *s, Client **pc, LayerSurface **pl);

/* The others */
extern void client_activate_surface(struct wlr_surface *s, int activated);

extern const char *client_get_appid(Client *c);

extern void client_get_geometry(Client *c, struct wlr_box *geom);

extern Client *client_get_parent(Client *c);

extern int client_has_children(Client *c);

extern const char *client_get_title(Client *c);

extern int client_is_float_type(Client *c);

extern int client_is_rendered_on_mon(Client *c, Monitor *m);

static inline int
client_is_stopped(Client *c)
{
	int pid;
	siginfo_t in = {0};

	wl_client_get_credentials(c->surface->client->client, &pid, NULL, NULL);
	if (waitid(P_PID, pid, &in, WNOHANG|WCONTINUED|WSTOPPED|WNOWAIT) < 0) {
		/* This process is not our child process, while is very unlikely that
		 * it is stopped, in order to do not skip frames, assume that it is. */
		if (errno == ECHILD)
			return 1;
	} else if (in.si_pid) {
		if (in.si_code == CLD_STOPPED || in.si_code == CLD_TRAPPED)
			return 1;
		if (in.si_code == CLD_CONTINUED)
			return 0;
	}

	return 0;
}

extern void client_notify_enter(struct wlr_surface *s, struct wlr_keyboard *kb);

extern void client_send_close(Client *c);

extern void client_set_border_color(Client *c, const float color[4]);

extern void client_set_fullscreen(Client *c, int fullscreen);

extern void client_set_scale(struct wlr_surface *s, float scale);

extern void client_set_tiled(Client *c, uint32_t edges);

extern void client_set_suspended(Client *c, int suspended);

extern int client_wants_fullscreen(Client *c);
