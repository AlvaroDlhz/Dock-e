//
// The look shared by every context menu of the dock.
//

namespace Plank
{
	/**
	 * Gives the context menus of the dock one look, whoever built them:
	 * the dock itself, an application through its quicklist, or a tray icon.
	 */
	public class ContextMenuStyle : Object
	{
		/**
		 * The style class which marks a menu as a context menu of the dock.
		 */
		public const string STYLE_CLASS = "plank-dock-context-menu";

		// The measures the launcher's own context window follows as well
		public const int RADIUS = 12;
		public const int PADDING = 6;
		public const int ROW_RADIUS = 8;

		// GTK puts every menu into a window of its own, which the theme paints
		// as a square behind the rounded menu unless it is told not to
		const string WINDOW_CLASS = "plank-context-menu-window";
		const string TRANSITION_KEY = "plank-context-menu-transition";

		static Gtk.CssProvider? provider = null;
		static string applied_css = "";

		/**
		 * Whether dark text is needed to be readable on the given color.
		 */
		public static bool is_light (Color color)
		{
			return 0.2126 * linearize (color.red) + 0.7152 * linearize (color.green)
				+ 0.0722 * linearize (color.blue) > 0.179;
		}

		static double linearize (double channel)
		{
			return channel <= 0.04045 ? channel / 12.92
				: Math.pow ((channel + 0.055) / 1.055, 2.4);
		}

		/**
		 * Styles a menu, and its submenus, as a context menu of the dock.
		 *
		 * @param menu the menu about to be shown
		 * @param controller the dock it belongs to
		 */
		public static void prepare (Gtk.Menu menu, DockController controller)
		{
			apply (menu.get_screen (), controller.renderer.theme.FillStartColor);
			mark (menu);

			// Fades the menu in, set up once for menus which are shown again
			if (menu.get_data<WindowTransition> (TRANSITION_KEY) != null)
				return;
			unowned Gtk.Window? toplevel = menu.get_toplevel () as Gtk.Window;
			if (toplevel == null)
				return;
			var transition = new WindowTransition (toplevel);
			unowned WindowTransition fade = transition;
			unowned DockPreferences prefs = controller.prefs;
			toplevel.show.connect_after (() => {
				fade.jump_to (0.0);
				fade.animate_to (1.0, Motion.duration (prefs, Motion.POPUP_OPEN_TIME));
			});
			menu.set_data<WindowTransition> (TRANSITION_KEY, transition);
		}

		static void mark (Gtk.Menu menu)
		{
			menu.get_style_context ().add_class (STYLE_CLASS);
			unowned Gtk.Widget? window = menu.get_toplevel ();
			if (window != null && window != menu)
				window.get_style_context ().add_class (WINDOW_CLASS);
			menu.reserve_toggle_size = true;
			foreach (unowned Gtk.Widget child in menu.get_children ()) {
				unowned Gtk.ImageMenuItem? image_item = child as Gtk.ImageMenuItem;
				if (image_item != null)
					image_item.always_show_image = true;
				unowned Gtk.MenuItem? item = child as Gtk.MenuItem;
				if (item == null)
					continue;
				unowned Gtk.Menu? submenu = item.get_submenu () as Gtk.Menu;
				if (submenu != null)
					mark (submenu);
			}
		}

		static void apply (Gdk.Screen screen, Color background)
		{
			var light = is_light (background);
			var foreground = light ? "24,27,32" : "255,255,255";
			var destructive = light ? "#a61b1b" : "#ff8b82";

			var menu = "." + STYLE_CLASS;
			var window = "." + WINDOW_CLASS;
			var css = "%s { background-color: rgb(%d,%d,%d); background-image: none; border: 1px solid rgba(%s,0.16); border-radius: %dpx; padding: %dpx; }"
				.printf (menu, (int) (background.red * 255), (int) (background.green * 255),
					(int) (background.blue * 255), foreground, RADIUS, PADDING);
			css += "%s { background: none; background-color: transparent; border: none; border-radius: 0; box-shadow: none; }"
				.printf (window);
			css += "%s decoration { background: none; border: none; border-radius: 0; box-shadow: none; margin: 0; }"
				.printf (window);
			css += "%s menuitem { min-width: 230px; min-height: 22px; color: rgba(%s,0.92); border-radius: %dpx; padding: 7px 10px; margin: 1px; transition: background-color 120ms ease; }"
				.printf (menu, foreground, ROW_RADIUS);
			css += "%s menuitem:hover { color: rgb(%s); background-color: rgba(%s,0.11); }"
				.printf (menu, foreground, foreground);
			css += "%s menuitem:disabled { color: rgba(%s,0.40); }".printf (menu, foreground);
			css += "%s menuitem image { color: rgba(%s,0.80); }".printf (menu, foreground);
			css += "%s menuitem arrow { color: rgba(%s,0.60); }".printf (menu, foreground);
			css += "%s .context-menu-header { min-height: 40px; padding: 7px 8px 8px 8px; margin-bottom: 4px; border-radius: %dpx; background-color: rgba(%s,0.06); }"
				.printf (menu, ROW_RADIUS, foreground);
			css += "%s .context-menu-header:disabled { color: rgb(%s); }".printf (menu, foreground);
			css += "%s .context-menu-title { color: rgb(%s); font-size: 14px; font-weight: bold; }"
				.printf (menu, foreground);
			css += "%s .context-menu-subtitle { color: rgba(%s,0.60); font-size: 11px; }"
				.printf (menu, foreground);
			css += "%s separator { min-height: 1px; margin: 5px 9px; background-color: rgba(%s,0.10); }"
				.printf (menu, foreground);
			css += "%s check, %s radio { color: rgb(%s); background: transparent; border-color: rgba(%s,0.45); }"
				.printf (menu, menu, foreground, foreground);
			css += "%s check:checked, %s radio:checked { color: white; background-color: #73d216; border-color: #73d216; }"
				.printf (menu, menu);
			css += "%s .destructive-action, %s .destructive-action image { color: %s; }"
				.printf (menu, menu, destructive);
			css += "%s .destructive-action:hover, %s .destructive-action:hover image { color: white; background-color: rgba(220,65,65,0.55); }"
				.printf (menu, menu);
			css += "%s .destructive-action:hover image { background-color: transparent; }".printf (menu);

			if (css == applied_css)
				return;
			applied_css = css;

			if (provider != null)
				Gtk.StyleContext.remove_provider_for_screen (screen, provider);
			provider = new Gtk.CssProvider ();
			try {
				provider.load_from_data (css);
			} catch (Error e) {
				warning ("Unable to style context menus: %s", e.message);
			}
			Gtk.StyleContext.add_provider_for_screen (screen, provider,
				Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
		}
	}
}
