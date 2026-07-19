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
					menu_pixbuf = new Gdk.Pixbuf.from_resource (G_RESOURCE_PATH + "/img/menu.svg");
				} catch (Error e) {
					warning ("Unable to load dock menu image: %s", e.message);
					return;
				}
			}

			var size = (int) (int.min (surface.Width, surface.Height) * 0.88);
			var scaled = menu_pixbuf.scale_simple (size, size, Gdk.InterpType.BILINEAR);
			unowned Cairo.Context cr = surface.Context;
			var x = (surface.Width - size) / 2.0;
			var y = (surface.Height - size) / 2.0;
			var radius = size * 0.18;

			cr.save ();
			cr.new_sub_path ();
			cr.arc (x + size - radius, y + radius, radius, -Math.PI_2, 0);
			cr.arc (x + size - radius, y + size - radius, radius, 0, Math.PI_2);
			cr.arc (x + radius, y + size - radius, radius, Math.PI_2, Math.PI);
			cr.arc (x + radius, y + radius, radius, Math.PI, Math.PI * 1.5);
			cr.close_path ();
			cr.clip ();
			Gdk.cairo_set_source_pixbuf (cr, scaled, x, y);
			cr.paint ();
			cr.restore ();
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
