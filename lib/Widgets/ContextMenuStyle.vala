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
			DockStyle.update (controller);
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
	}
}
