//
// Native application launcher entry point.
//

namespace Plank
{
	public class LauncherItem : DockItem
	{
		Gdk.Pixbuf? menu_pixbuf = null;

		public LauncherItem ()
		{
			Object (Prefs: new DockItemPreferences (), Text: _("Applications"),
				Icon: "view-app-grid-symbolic");
		}

		public override bool can_be_removed ()
		{
			return false;
		}

		protected override void draw_icon (Surface surface)
		{
			if (menu_pixbuf == null) {
				try {
					menu_pixbuf = new Gdk.Pixbuf.from_resource (G_RESOURCE_PATH + "/img/menu-2.svg");
				} catch (Error e) {
					warning ("Unable to load dock menu image: %s", e.message);
					return;
				}
			}

			unowned Cairo.Context cr = surface.Context;
			var extent = (double) int.min (surface.Width, surface.Height);

			var box = extent * 0.90;
			var box_x = (surface.Width - box) / 2.0;
			var box_y = (surface.Height - box) / 2.0;
			var box_radius = box * 0.22;
			var line_width = double.max (1.0, extent * 0.028);

			cr.save ();
			Theme.draw_rounded_rect (cr, box_x, box_y, box, box,
				box_radius, box_radius, line_width);
			cr.set_line_width (line_width);
			cr.set_source_rgba (1.0, 1.0, 1.0, 0.92);
			cr.stroke ();
			cr.restore ();

			var size = (int) (extent * 0.50);
			var scaled = menu_pixbuf.scale_simple (size, size, Gdk.InterpType.BILINEAR);
			var x = (surface.Width - size) / 2.0;
			var y = (surface.Height - size) / 2.0;

			Gdk.cairo_set_source_pixbuf (cr, scaled, x, y);
			cr.paint ();
		}

		protected override AnimationType on_clicked (PopupButton button, Gdk.ModifierType mod, uint32 event_time)
		{
			if (button == PopupButton.LEFT) {
				unowned DockController? dock = get_dock ();
				if (dock != null)
					dock.launcher.toggle (this);
				return AnimationType.DARKEN;
			}

			return AnimationType.NONE;
		}

		protected override AnimationType on_hovered ()
		{
			return AnimationType.NONE;
		}

		public override Gee.ArrayList<Gtk.MenuItem> get_menu_items ()
		{
			var items = new Gee.ArrayList<Gtk.MenuItem> ();
			var open_item = create_menu_item (_("Open _Applications"), "view-app-grid-symbolic");
			open_item.activate.connect (() => {
				unowned DockController? dock = get_dock ();
				if (dock != null)
					dock.launcher.show_for_item (this);
			});
			items.add (open_item);
			return items;
		}
	}

	public class LauncherProvider : DockItemProvider
	{
		TrayToggleItem tray_toggle;

		public LauncherProvider ()
		{
			Object ();
			add (new LauncherItem ());
			add (new WorkspaceItem ());
			var update_command = UpdateManagerItem.available_command ();
			if (update_command != null)
				add (new UpdateManagerItem (update_command));
			tray_toggle = new TrayToggleItem ();
			add (tray_toggle);
		}

		public override bool can_accept_drop (Gee.ArrayList<string> uris)
		{
			return false;
		}

		public override bool move_to (DockElement move, DockElement target)
		{
			return false;
		}
	}
}
