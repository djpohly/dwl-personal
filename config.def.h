/* Taken from https://github.com/djpohly/dwl/issues/466 */
#define COLOR(hex)    { ((hex >> 24) & 0xFF) / 255.0f, \
                        ((hex >> 16) & 0xFF) / 255.0f, \
                        ((hex >> 8) & 0xFF) / 255.0f, \
                        (hex & 0xFF) / 255.0f }
/* appearance */
static const int sloppyfocus               = 1;  /* focus follows mouse */
static const int bypass_surface_visibility = 0;  /* 1 means idle inhibitors will disable idle tracking even if it's surface isn't visible  */
static const unsigned int borderpx         = 1;  /* border pixel of windows */
static const float rootcolor[]             = COLOR(0x1d262fff);
static const float bordercolor[]           = COLOR(0x27323fff);
static const float focuscolor[]            = COLOR(0x717a77ff);
static const float urgentcolor[]           = COLOR(0x7eb6f6ff);
/* This conforms to the xdg-protocol. Set the alpha to zero to restore the old behavior */
static const float fullscreen_bg[]         = {0.0f, 0.0f, 0.0f, 1.0f}; /* You can also use glsl colors */
/* cursor warping */
static const bool cursor_warp = 1;

/* tagging - TAGCOUNT must be no greater than 31 */
#define TAGCOUNT (9)

/* logging */
static int log_level = WLR_ERROR;

/* NOTE: ALWAYS keep a rule declared even if you don't use rules (e.g leave at least one example) */
static const Rule rules[] = {
	/* app_id             title       tags mask     isfloating   monitor */
	/* examples: */
	{ "mpv",              NULL,       0,            1,           -1 },
};

/* layout(s) */
static const Layout layouts[] = {
	/* symbol     arrange function */
	{ "[]=",      tile },
	{ "><>",      NULL },    /* no layout function means floating behavior */
	{ "[M]",      monocle },
	{ "TTT",      bstack },
	{ "===",      bstackhoriz },
};

/* monitors */
/* (x=-1, y=-1) is reserved as an "autoconfigure" monitor position indicator
 * WARNING: negative values other than (-1, -1) cause problems with Xwayland clients
 * https://gitlab.freedesktop.org/xorg/xserver/-/issues/899
*/
/* NOTE: ALWAYS add a fallback rule, even if you are completely sure it won't be used */
static const MonitorRule monrules[] = {
	/* name       mfact  nmaster scale layout       rotate/reflect                x    y */
	/* example of a HiDPI laptop monitor:
	{ "eDP-1",    0.5f,  1,      2,    &layouts[0], WL_OUTPUT_TRANSFORM_NORMAL,   -1,  -1 },
	*/

	/* Now using kanshi */
	/* { "eDP-1",    0.5f,  1,      2,    &layouts[0], WL_OUTPUT_TRANSFORM_NORMAL,   -1,  -1 }, */
	/* { "HDMI-A-1", 0.5f,  1,      2,    &layouts[0], WL_OUTPUT_TRANSFORM_NORMAL,   -1,  -1 }, */
	/* { NULL,       0.5f,  1,      1,    &layouts[0], WL_OUTPUT_TRANSFORM_NORMAL,   -1,  -1 }, */

	/* defaults */
	{ "DP-11",    0.5,  1,      1,    &layouts[3], WL_OUTPUT_TRANSFORM_NORMAL,   0,  0 },
	{ NULL,       0.5,  1,      1,    &layouts[0], WL_OUTPUT_TRANSFORM_NORMAL,   0,  0 },
};

/* keyboard */
static const struct xkb_rule_names xkb_rules = {
	/* can specify fields: rules, model, layout, variant, options */
	/* example:
	.options = "ctrl:nocaps",
	*/
	.layout = "us",
	.variant = "dvorak",
	.options = "ctrl:nocaps,altwin:swap_lalt_lwin",
};

static const int repeat_rate = 20;
static const int repeat_delay = 200;

/* Trackpad */
static const int tap_to_click = 1;
static const int tap_and_drag = 1;
static const int drag_lock = 1;
static const int natural_scrolling = 1;
static const int disable_while_typing = 1;
static const int left_handed = 0;
static const int middle_button_emulation = 0;
/* You can choose between:
LIBINPUT_CONFIG_SCROLL_NO_SCROLL
LIBINPUT_CONFIG_SCROLL_2FG
LIBINPUT_CONFIG_SCROLL_EDGE
LIBINPUT_CONFIG_SCROLL_ON_BUTTON_DOWN
*/
static const enum libinput_config_scroll_method scroll_method = LIBINPUT_CONFIG_SCROLL_2FG;

/* You can choose between:
LIBINPUT_CONFIG_CLICK_METHOD_NONE
LIBINPUT_CONFIG_CLICK_METHOD_BUTTON_AREAS
LIBINPUT_CONFIG_CLICK_METHOD_CLICKFINGER
*/
static const enum libinput_config_click_method click_method = LIBINPUT_CONFIG_CLICK_METHOD_BUTTON_AREAS;

/* You can choose between:
LIBINPUT_CONFIG_SEND_EVENTS_ENABLED
LIBINPUT_CONFIG_SEND_EVENTS_DISABLED
LIBINPUT_CONFIG_SEND_EVENTS_DISABLED_ON_EXTERNAL_MOUSE
*/
static const uint32_t send_events_mode = LIBINPUT_CONFIG_SEND_EVENTS_ENABLED;

/* You can choose between:
LIBINPUT_CONFIG_ACCEL_PROFILE_FLAT
LIBINPUT_CONFIG_ACCEL_PROFILE_ADAPTIVE
*/
static const enum libinput_config_accel_profile accel_profile = LIBINPUT_CONFIG_ACCEL_PROFILE_ADAPTIVE;
static const double accel_speed = 0.0;

/* You can choose between:
LIBINPUT_CONFIG_TAP_MAP_LRM -- 1/2/3 finger tap maps to left/right/middle
LIBINPUT_CONFIG_TAP_MAP_LMR -- 1/2/3 finger tap maps to left/middle/right
*/
static const enum libinput_config_tap_button_map button_map = LIBINPUT_CONFIG_TAP_MAP_LRM;

/* If you want to use the windows key for MODKEY, use WLR_MODIFIER_LOGO */
#define MODKEY WLR_MODIFIER_LOGO

#define TAGKEYS(KEY,SKEY,TAG) \
	{ MODKEY,                    KEY,            view,            {.ui = 1 << TAG} }, \
	{ MODKEY|WLR_MODIFIER_CTRL,  KEY,            toggleview,      {.ui = 1 << TAG} }, \
	{ MODKEY|WLR_MODIFIER_SHIFT, SKEY,           tag,             {.ui = 1 << TAG} }, \
	{ MODKEY|WLR_MODIFIER_CTRL|WLR_MODIFIER_SHIFT,SKEY,toggletag, {.ui = 1 << TAG} }

/* helper for spawning shell commands in the pre dwm-5.0 fashion */
#define SHCMD(cmd) { .v = (const char*[]){ "/bin/sh", "-c", cmd, NULL } }

/* commands */
static const char *termcmd[] = { "foot", NULL };
static const char *menucmd[] = { "wmenu-run", NULL };
static const char *lockcmd[]  = { "wllock", NULL };
static const char *wificmd[]  = { "wpass", NULL };
static const char *lowervolcmd[]  = { "amixer", "-q", "sset", "Master", "3%-", NULL };
static const char *raisevolcmd[]  = { "amixer", "-q", "sset", "Master", "3%+", NULL };
static const char *mutecmd[]  = { "amixer", "-q", "sset", "Master", "toggle", NULL };
static const char *playcmd[]  = { "mpc", "-q", "toggle", NULL };
static const char *stopcmd[]  = { "mpc", "-q", "stop", NULL };
static const char *prevcmd[]  = { "mpc", "-q", "prev", NULL };
static const char *nextcmd[]  = { "mpc", "-q", "next", NULL };
static const char *ffcmd[]  = { "mpc", "-q", "seek", "+20", NULL };
static const char *rewcmd[]  = { "mpc", "-q", "seek", "-20", NULL };
static const char *brightupcmd[] = { "xbacklight", "-inc", "10", "-fps", "30", "-perceived", NULL };
static const char *brightdncmd[] = { "xbacklight", "-dec", "10", "-fps", "30", "-perceived", NULL };
static const char *quitcmd[] = { "/bin/sh", "-c", "s6-svscanctl -t \"${ANOPA_SCANDIR:-.local/share/services}/.scandir\"", NULL };
static const char *mediacmd[] = { "mpvclip", NULL };
static const char *mediadlcmd[] = { "dlclip", NULL };
static const char *pbutcmd[]  = { "pbut", NULL };

static const Key keys[] = {
	/* Note that Shift changes certain key codes: c -> C, 2 -> at, etc. */
	/* modifier                  key                 function        argument */
	{ MODKEY|WLR_MODIFIER_SHIFT, XKB_KEY_Return,   spawn,         {.v = termcmd} },
	{ MODKEY,                    XKB_KEY_r,        spawn,         {.v = menucmd} },
	{ MODKEY,                    XKB_KEY_space,    spawn,         {.v = lockcmd},     .override_lock = 1 },
	{ MODKEY,                    XKB_KEY_w,        spawn,         {.v = wificmd},     .override_lock = 1  },
	{ 0,                     XKB_KEY_XF86PowerOff, spawn,         {.v = pbutcmd} },
	{ 0,             XKB_KEY_XF86AudioLowerVolume, spawn,         {.v = lowervolcmd},     .override_lock = 1  },
	{ 0,             XKB_KEY_XF86AudioRaiseVolume, spawn,         {.v = raisevolcmd},     .override_lock = 1  },
	{ 0,                    XKB_KEY_XF86AudioMute, spawn,         {.v = mutecmd},     .override_lock = 1  },
	{ 0,                    XKB_KEY_XF86AudioPlay, spawn,         {.v = playcmd},     .override_lock = 1  },
	{ 0,                    XKB_KEY_XF86AudioStop, spawn,         {.v = stopcmd},     .override_lock = 1  },
	{ 0,                    XKB_KEY_XF86AudioPrev, spawn,         {.v = prevcmd},     .override_lock = 1  },
	{ 0,                    XKB_KEY_XF86AudioNext, spawn,         {.v = nextcmd},     .override_lock = 1  },
	{ 0,              XKB_KEY_XF86MonBrightnessUp, spawn,         {.v = brightupcmd},     .override_lock = 1  },
	{ 0,            XKB_KEY_XF86MonBrightnessDown, spawn,         {.v = brightdncmd},     .override_lock = 1  },
	{ MODKEY,                    XKB_KEY_Next,     spawn,         {.v = lowervolcmd},     .override_lock = 1  },
	{ MODKEY,                    XKB_KEY_Prior,    spawn,         {.v = raisevolcmd},     .override_lock = 1  },
	{ MODKEY|WLR_MODIFIER_SHIFT, XKB_KEY_Next,     spawn,         {.v = mutecmd},     .override_lock = 1  },
	{ MODKEY,                    XKB_KEY_Insert,   spawn,         {.v = playcmd},     .override_lock = 1  },
	{ MODKEY,                    XKB_KEY_Delete,   spawn,         {.v = stopcmd},     .override_lock = 1  },
	{ MODKEY,                    XKB_KEY_Home,     spawn,         {.v = prevcmd},     .override_lock = 1  },
	{ MODKEY,                    XKB_KEY_End,      spawn,         {.v = nextcmd},     .override_lock = 1  },
	{ MODKEY,                    XKB_KEY_Left,     spawn,         {.v = rewcmd},     .override_lock = 1  },
	{ MODKEY,                    XKB_KEY_Right,    spawn,         {.v = ffcmd},     .override_lock = 1  },
	{ MODKEY,                    XKB_KEY_a,        spawn,         {.v = mediacmd} },
	{ MODKEY|WLR_MODIFIER_SHIFT, XKB_KEY_A,        spawn,         {.v = mediadlcmd} },
	{ MODKEY,                    XKB_KEY_t,        focusstack,    {.i = +1} },
	{ MODKEY,                    XKB_KEY_n,        focusstack,    {.i = -1} },
	{ MODKEY,                    XKB_KEY_Tab,      focusstack,    {.i = +1} },
	{ MODKEY|WLR_MODIFIER_SHIFT, XKB_KEY_ISO_Left_Tab, focusstack,{.i = -1} },
	{ MODKEY|WLR_MODIFIER_SHIFT, XKB_KEY_T,        movestack,     {.i = +1} },
	{ MODKEY|WLR_MODIFIER_SHIFT, XKB_KEY_N,        movestack,     {.i = -1} },
	{ MODKEY|WLR_MODIFIER_SHIFT, XKB_KEY_H,        incnmaster,    {.i = +1} },
	{ MODKEY|WLR_MODIFIER_SHIFT, XKB_KEY_S,        incnmaster,    {.i = -1} },
	{ MODKEY,                    XKB_KEY_h,        setmfact,      {.f = -0.05f} },
	{ MODKEY,                    XKB_KEY_s,        setmfact,      {.f = +0.05f} },
	{ MODKEY,                    XKB_KEY_Return,   zoom,          {0} },
	{ MODKEY,                    XKB_KEY_Escape,   killclient,    {0} },
	{ MODKEY|WLR_MODIFIER_SHIFT, XKB_KEY_L,        setlayout,     {.v = &layouts[0]} },
	{ MODKEY|WLR_MODIFIER_SHIFT, XKB_KEY_F,        setlayout,     {.v = &layouts[1]} },
	{ MODKEY|WLR_MODIFIER_SHIFT, XKB_KEY_M,        setlayout,     {.v = &layouts[2]} },
	{ MODKEY,                    XKB_KEY_l,        setlayout,     {.v = &layouts[3]} },
	{ MODKEY,                    XKB_KEY_f,        togglefloating,{0} },
	{ MODKEY,                    XKB_KEY_0,        view,          {.ui = ~0} },
	{ MODKEY|WLR_MODIFIER_SHIFT, XKB_KEY_parenright, tag,         {.ui = ~0} },
	{ MODKEY,                    XKB_KEY_apostrophe, focusmon,    {.i = WLR_DIRECTION_LEFT} },
	{ MODKEY,                    XKB_KEY_comma,    focusmon,      {.i = WLR_DIRECTION_RIGHT} },
	{ MODKEY|WLR_MODIFIER_SHIFT, XKB_KEY_quotedbl, tagmon,        {.i = WLR_DIRECTION_LEFT} },
	{ MODKEY|WLR_MODIFIER_SHIFT, XKB_KEY_less,     tagmon,        {.i = WLR_DIRECTION_RIGHT} },
	TAGKEYS(          XKB_KEY_1, XKB_KEY_exclam,                     0),
	TAGKEYS(          XKB_KEY_2, XKB_KEY_at,                         1),
	TAGKEYS(          XKB_KEY_3, XKB_KEY_numbersign,                 2),
	TAGKEYS(          XKB_KEY_4, XKB_KEY_dollar,                     3),
	TAGKEYS(          XKB_KEY_5, XKB_KEY_percent,                    4),
	TAGKEYS(          XKB_KEY_6, XKB_KEY_asciicircum,                5),
	TAGKEYS(          XKB_KEY_7, XKB_KEY_ampersand,                  6),
	TAGKEYS(          XKB_KEY_8, XKB_KEY_asterisk,                   7),
	TAGKEYS(          XKB_KEY_9, XKB_KEY_parenleft,                  8),
	{ MODKEY|WLR_MODIFIER_SHIFT, XKB_KEY_BackSpace, quit,         {0}, .override_lock = 1 },

	/* Ctrl-Alt-Backspace and Ctrl-Alt-Fx used to be handled by X server */
	{ WLR_MODIFIER_CTRL|WLR_MODIFIER_ALT,XKB_KEY_Terminate_Server, quit, {0}, .override_lock = 1 },
	/* Ctrl-Alt-Fx is used to switch to another VT, if you don't know what a VT is
	 * do not remove them.
	 */
#define CHVT(n) { WLR_MODIFIER_CTRL|WLR_MODIFIER_ALT,XKB_KEY_XF86Switch_VT_##n, chvt, {.ui = (n)}, .override_lock = 1 }
	CHVT(1), CHVT(2), CHVT(3), CHVT(4), CHVT(5), CHVT(6),
	CHVT(7), CHVT(8), CHVT(9), CHVT(10), CHVT(11), CHVT(12),
};

static const Button buttons[] = {
	{ MODKEY, BTN_LEFT,   moveresize,     {.ui = CurMove} },
	{ MODKEY, BTN_MIDDLE, togglefloating, {0} },
	{ MODKEY, BTN_RIGHT,  moveresize,     {.ui = CurResize} },
};
