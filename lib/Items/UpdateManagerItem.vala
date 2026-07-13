// Fixed entry point for the system update manager.

namespace Plank
{
	public class UpdateManagerItem : DockItem
	{
		string command;
		bool updates_available = false;
		Gdk.Pixbuf? update_pixbuf;
		unowned UpdateService update_service;
		ulong update_state_changed_id = 0UL;

		public UpdateManagerItem (string command)
		{
			Object (Prefs: new DockItemPreferences (), Text: _("Update Manager"),
				Icon: "software-update-available-symbolic");
			this.command = command;
		}

		construct
		{
			update_service = UpdateService.get_default ();
			update_state_changed_id = update_service.state_changed.connect (sync_update_state);
			sync_update_state ();
		}

		~UpdateManagerItem ()
		{
			if (update_state_changed_id > 0UL)
				SignalHandler.disconnect (update_service, update_state_changed_id);
		}

		public static string? available_command ()
		{
			if (Environment.find_program_in_path ("mintupdate") != null)
				return "mintupdate";
			if (Environment.find_program_in_path ("update-manager") != null)
				return "update-manager";
			if (Environment.find_program_in_path ("gnome-software") != null)
				return "gnome-software --mode=updates";
			if (Environment.find_program_in_path ("plasma-discover") != null)
				return "plasma-discover --mode update";
			return null;
		}

		public override bool can_be_removed ()
		{
			return false;
		}

		void sync_update_state ()
		{
			if (updates_available != update_service.updates_available) {
				updates_available = update_service.updates_available;
				reset_icon_buffer ();
			}
		}

		protected override void draw_icon (Surface surface)
		{
			var size = double.min (surface.Width, surface.Height);
			var icon_size = (int) (size * 0.54);
			try {
				if (update_pixbuf == null)
					update_pixbuf = new Gdk.Pixbuf.from_resource_at_scale (
						G_RESOURCE_PATH + "/lucide/refresh-cw.svg", icon_size, icon_size, true);
				unowned Cairo.Context cr = surface.Context;
				Gdk.cairo_set_source_pixbuf (cr, update_pixbuf,
					(surface.Width - update_pixbuf.width) / 2.0,
					(surface.Height - update_pixbuf.height) / 2.0);
				cr.paint_with_alpha (0.92);
				if (updates_available) {
					var cx = surface.Width * 0.70;
					var cy = surface.Height * 0.28;
					var radius = size * 0.075;
					cr.set_source_rgba (0.10, 0.14, 0.10, 0.95);
					cr.arc (cx, cy, radius + size * 0.025, 0, Math.PI * 2.0);
					cr.fill ();
					cr.set_source_rgba (0.45, 0.82, 0.09, 1.0);
					cr.arc (cx, cy, radius, 0, Math.PI * 2.0);
					cr.fill ();
				}
			} catch (Error e) {
				warning ("Unable to load update icon: %s", e.message);
			}
		}

		protected override AnimationType on_hovered ()
		{
			return AnimationType.LIGHTEN;
		}

		protected override AnimationType on_clicked (PopupButton button,
			Gdk.ModifierType mod, uint32 event_time)
		{
			if (button == PopupButton.LEFT) {
				launch ();
				return AnimationType.DARKEN;
			}
			return AnimationType.NONE;
		}

		public void launch ()
		{
			try {
				var app = AppInfo.create_from_commandline (command, _("Update Manager"),
					AppInfoCreateFlags.SUPPORTS_STARTUP_NOTIFICATION);
				app.launch (null, null);
				update_service.schedule_refresh (2);
			} catch (Error e) {
				warning ("Unable to open update manager: %s", e.message);
			}
		}

		public override Gee.ArrayList<Gtk.MenuItem> get_menu_items ()
		{
			var items = new Gee.ArrayList<Gtk.MenuItem> ();
			var open = create_menu_item (_("Open _Update Manager"),
				"software-update-available-symbolic");
			open.activate.connect (launch);
			items.add (open);
			return items;
		}
	}
}
