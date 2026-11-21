//
// The style sheets shared by every window of the dock.
//

namespace Plank
{
	/**
	 * Gives the windows around the bar their look.
	 *
	 * The rules live in one style sheet which never changes. What follows the
	 * theme of the bar are a handful of named colors it refers to, so a change
	 * of theme replaces a few lines instead of every rule. A style sheet of
	 * the user is read last and can redefine those colors or restate any rule.
	 */
	public class DockStyle : Object
	{
		/**
		 * The style sheet of the user, looked for in the folder of the dock.
		 */
		public const string USER_FILE_NAME = "style.css";

		const string RESOURCE = G_RESOURCE_PATH + "/style/dock-e.css";
		// An editor writes a file in several steps
		const uint RELOAD_DELAY = 150U;

		static Gtk.CssProvider? base_provider = null;
		static Gtk.CssProvider? colors_provider = null;
		static Gtk.CssProvider? user_provider = null;
		static string applied_colors = "";
		static File? user_file = null;
		static FileMonitor? user_monitor = null;
		static uint reload_timer_id = 0U;

		/**
		 * Loads the rules, which is all a window needs that does not follow
		 * the theme of a dock.
		 */
		public static void ensure_base (Gdk.Screen screen)
		{
			if (base_provider != null)
				return;
			base_provider = new Gtk.CssProvider ();
			base_provider.load_from_resource (RESOURCE);
			Gtk.StyleContext.add_provider_for_screen (screen, base_provider,
				Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
			// The rules refer to the colors, which must exist from the start
			Color bar = { 0.16, 0.16, 0.16, 1.0 };
			set_colors (screen, describe_colors (bar, default_accent ()));
		}

		/**
		 * Makes the colors follow the theme of a dock, and reads the style
		 * sheet of its user. Costs next to nothing if neither has changed.
		 */
		public static void update (DockController controller)
		{
			unowned Gdk.Screen screen = controller.window.get_screen ();
			ensure_base (screen);
			set_colors (screen, describe_colors (controller.renderer.theme.FillStartColor,
				controller.accent.color));
			watch_user_file (screen, controller.config_folder.get_child (USER_FILE_NAME));
		}

		static Gdk.RGBA default_accent ()
		{
			Gdk.RGBA accent = {};
			accent.parse (AccentColor.DEFAULT);
			return accent;
		}

		/**
		 * The named colors, as a style sheet.
		 */
		static string describe_colors (Color bar, Gdk.RGBA accent)
		{
			var red = channel (bar.red);
			var green = channel (bar.green);
			var blue = channel (bar.blue);
			// printf follows the locale and writes "0,850" in Spanish, which is
			// not a number in CSS, so the decimals are put together by hand
			var opacity = (int) Math.round (bar.alpha.clamp (0.0, 1.0) * 1000.0);
			var light = ContextMenuStyle.is_light (bar);

			var css = new StringBuilder ();
			css.append_printf ("@define-color dock_e_bar rgb(%d,%d,%d);\n", red, green, blue);
			css.append_printf ("@define-color dock_e_panel rgba(%d,%d,%d,%d.%03d);\n",
				red, green, blue, opacity / 1000, opacity % 1000);
			css.append_printf ("@define-color dock_e_card rgb(%d,%d,%d);\n",
				int.min (255, red + 12), int.min (255, green + 12), int.min (255, blue + 12));
			css.append_printf ("@define-color dock_e_card_hover rgb(%d,%d,%d);\n",
				int.min (255, red + 24), int.min (255, green + 24), int.min (255, blue + 24));
			css.append_printf ("@define-color dock_e_fg rgb(%s);\n", light ? "24,27,32" : "255,255,255");
			css.append_printf ("@define-color dock_e_fg_muted rgb(%s);\n", light ? "48,52,58" : "255,255,255");
			css.append_printf ("@define-color dock_e_accent rgb(%d,%d,%d);\n",
				channel (accent.red), channel (accent.green), channel (accent.blue));
			css.append_printf ("@define-color dock_e_success %s;\n", light ? "#286400" : "#a8ef70");
			css.append_printf ("@define-color dock_e_destructive %s;\n", light ? "#a61b1b" : "#ff8b82");
			css.append_printf ("@define-color dock_e_attention %s;\n", light ? "rgb(168,88,0)" : "rgb(255,190,80)");
			return css.str;
		}

		static int channel (double value)
		{
			return (int) Math.round (value.clamp (0.0, 1.0) * 255.0);
		}

		static void set_colors (Gdk.Screen screen, string css)
		{
			// Swapping a provider restyles every widget, only do it for real changes
			if (css == applied_colors)
				return;
			applied_colors = css;
			var provider = new Gtk.CssProvider ();
			try {
				provider.load_from_data (css);
			} catch (Error e) {
				warning ("Unable to define the colors of the dock: %s", e.message);
				return;
			}
			// The new colors are in place before the old ones go
			Gtk.StyleContext.add_provider_for_screen (screen, provider,
				Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
			if (colors_provider != null)
				Gtk.StyleContext.remove_provider_for_screen (screen, colors_provider);
			colors_provider = provider;
		}

		static void watch_user_file (Gdk.Screen screen, File file)
		{
			if (user_file != null && user_file.equal (file))
				return;
			user_file = file;
			try {
				user_monitor = file.monitor_file (FileMonitorFlags.NONE);
				user_monitor.changed.connect (() => {
					if (reload_timer_id > 0U)
						Source.remove (reload_timer_id);
					reload_timer_id = Timeout.add (RELOAD_DELAY, () => {
						reload_timer_id = 0U;
						load_user_file (screen);
						return false;
					});
				});
			} catch (Error e) {
				warning ("Changes to '%s' will not be noticed: %s", file.get_path (), e.message);
			}
			load_user_file (screen);
		}

		static void load_user_file (Gdk.Screen screen)
		{
			if (user_provider != null) {
				Gtk.StyleContext.remove_provider_for_screen (screen, user_provider);
				user_provider = null;
			}
			if (user_file == null || !user_file.query_exists ())
				return;
			var path = user_file.get_path ();
			var provider = new Gtk.CssProvider ();
			provider.parsing_error.connect ((section, error) => {
				warning ("%s, line %u: %s", path, section.get_start_line () + 1, error.message);
			});
			try {
				provider.load_from_file (user_file);
			} catch (Error e) {
				// Each mistake was reported above, the rest of the file still counts
			}
			Gtk.StyleContext.add_provider_for_screen (screen, provider,
				Gtk.STYLE_PROVIDER_PRIORITY_USER);
			user_provider = provider;
			debug ("Loaded the style sheet '%s'", path);
		}
	}
}
