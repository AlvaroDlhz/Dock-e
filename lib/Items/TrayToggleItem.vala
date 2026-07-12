// Native, collapsible StatusNotifierItem host for Dock-e.

namespace Plank
{
	[DBus (name = "org.kde.StatusNotifierWatcher")]
	interface StatusNotifierWatcher : Object
	{
		public abstract string[] RegisteredStatusNotifierItems { owned get; }
		public signal void StatusNotifierItemRegistered (string item);
		public signal void StatusNotifierItemUnregistered (string item);
	}

	public class TrayToggleItem : DockItem
	{
		public signal void tray_changed ();
		public signal void expansion_changed (bool expanded);
		StatusNotifierWatcher? watcher;
		public bool Expanded { get; private set; default = false; }
		int item_count = 0;

		public TrayToggleItem ()
		{
			Object (Prefs: new DockItemPreferences (), Text: _("Background applications"));
			Button = PopupButton.LEFT;
			try {
				watcher = Bus.get_proxy_sync<StatusNotifierWatcher> (BusType.SESSION,
					"org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher");
				watcher.StatusNotifierItemRegistered.connect (() => refresh ());
				watcher.StatusNotifierItemUnregistered.connect (() => refresh ());
				refresh ();
			} catch (Error e) {
				warning ("Status notifier watcher unavailable: %s", e.message);
			}
		}

		void refresh ()
		{
			item_count = identifiers ().length;
			Text = ngettext ("%d background application", "%d background applications", item_count).printf (item_count);
			reset_icon_buffer ();
			tray_changed ();
		}

		public string[] identifiers ()
		{
			return watcher == null ? new string[0] : watcher.RegisteredStatusNotifierItems;
		}

		public override bool can_be_removed () { return false; }
		protected override AnimationType on_hovered () { return AnimationType.NONE; }

		protected override AnimationType on_clicked (PopupButton button, Gdk.ModifierType mod, uint32 time)
		{
			if (button != PopupButton.LEFT)
				return AnimationType.NONE;
			Expanded = !Expanded;
			reset_icon_buffer ();
			expansion_changed (Expanded);
			return AnimationType.NONE;
		}

		protected override void draw_icon (Surface surface)
		{
			unowned Cairo.Context cr = surface.Context;
			var cx = surface.Width / 2.0;
			var cy = surface.Height / 2.0;
			var span = int.min (surface.Width, surface.Height) * 0.15;
			cr.set_source_rgba (1, 1, 1, 0.92);
			cr.set_line_width (2.2);
			cr.set_line_cap (Cairo.LineCap.ROUND);
			if (Expanded) {
				cr.move_to (cx - span * 0.45, cy - span);
				cr.line_to (cx + span * 0.55, cy);
				cr.line_to (cx - span * 0.45, cy + span);
			} else {
				cr.move_to (cx - span, cy - span * 0.35);
				cr.line_to (cx, cy + span * 0.55);
				cr.line_to (cx + span, cy - span * 0.35);
			}
			cr.stroke ();
		}
	}

	public class TrayStatusItem : DockItem
	{
		DBusProxy? proxy;
		string status = "Active";

		public TrayStatusItem (string identifier) throws Error
		{
			// Construct the GObject before assigning owned fields.  Calling Object()
			// afterwards resets them and used to unref an invalid proxy here.
			Object (Prefs: new DockItemPreferences ());
			string service;
			string path;
			parse_identifier (identifier, out service, out path);
			proxy = new DBusProxy.for_bus_sync (BusType.SESSION, DBusProxyFlags.NONE,
				null, service, path, "org.kde.StatusNotifierItem");
			Button = PopupButton.LEFT | PopupButton.RIGHT;
			update_properties ();
			proxy.g_properties_changed.connect (() => update_properties ());
		}

		void update_properties ()
		{
			if (proxy == null)
				return;
			var title = proxy.get_cached_property ("Title");
			var icon = proxy.get_cached_property ("IconName");
			var new_status = proxy.get_cached_property ("Status");
			Text = title == null ? _("Background application") : title.get_string ();
			Icon = icon == null || icon.get_string () == ""
				? "application-x-executable-symbolic" : icon.get_string ();
			status = new_status == null ? "Active" : new_status.get_string ();
			Indicator = status == "NeedsAttention" ? IndicatorState.SINGLE : IndicatorState.NONE;
			reset_icon_buffer ();
		}

		public override bool can_be_removed () { return false; }
		protected override AnimationType on_hovered () { return AnimationType.LIGHTEN; }

		protected override void draw_icon (Surface surface)
		{
			// Tray applications often provide large, detailed icons.  Keep their
			// visual footprint aligned with Dock-e's compact system controls.
			var target = (int) (double.min (surface.Width, surface.Height) * 0.44);
			Cairo.Surface? icon_surface = null;
			Gdk.Pixbuf? pixbuf = ForcePixbuf;
			if (pixbuf == null) {
				double x_scale = 1.0, y_scale = 1.0;
				surface.Internal.get_device_scale (out x_scale, out y_scale);
				icon_surface = DrawingService.load_icon_for_scale (Icon, target, target,
					(int) double.max (x_scale, y_scale));
				if (icon_surface != null)
					icon_surface.set_device_scale (1.0, 1.0);
			} else {
				pixbuf = DrawingService.ar_scale (pixbuf, target, target);
			}
			unowned Cairo.Context cr = surface.Context;
			if (pixbuf != null) {
				Gdk.cairo_set_source_pixbuf (cr, pixbuf,
					(surface.Width - pixbuf.width) / 2.0, (surface.Height - pixbuf.height) / 2.0);
				cr.paint_with_alpha (0.92);
			} else if (icon_surface != null) {
				cr.set_source_surface (icon_surface,
					(surface.Width - target) / 2.0, (surface.Height - target) / 2.0);
				cr.paint_with_alpha (0.92);
			}
		}

		protected override AnimationType on_clicked (PopupButton button, Gdk.ModifierType mod, uint32 time)
		{
			if (button == PopupButton.LEFT)
				call_coordinates ("Activate");
			else if (button == PopupButton.RIGHT)
				call_coordinates ("ContextMenu");
			return AnimationType.DARKEN;
		}

		protected override AnimationType on_scrolled (Gdk.ScrollDirection direction,
			Gdk.ModifierType mod, uint32 event_time)
		{
			if (proxy == null)
				return AnimationType.NONE;
			var delta = direction == Gdk.ScrollDirection.UP || direction == Gdk.ScrollDirection.LEFT ? 1 : -1;
			proxy.call.begin ("Scroll", new Variant ("(is)", delta, "vertical"),
				DBusCallFlags.NONE, -1, null);
			return AnimationType.NONE;
		}

		void call_coordinates (string method)
		{
			if (proxy == null)
				return;
			unowned DockController? dock = get_dock ();
			int x = 0, y = 0;
			if (dock != null) {
				var rect = dock.position_manager.get_screen_region_for_item (this);
				x = rect.x + rect.width / 2;
				y = rect.y + rect.height / 2;
			}
			proxy.call.begin (method, new Variant ("(ii)", x, y), DBusCallFlags.NONE, -1, null);
		}

		static void parse_identifier (string identifier, out string service, out string path)
		{
			var slash = identifier.index_of_char ('/');
			if (slash > 0) {
				service = identifier.substring (0, slash);
				path = identifier.substring (slash);
			} else {
				service = identifier;
				path = "/StatusNotifierItem";
			}
		}
	}

	public class TrayOverflowItem : DockItem
	{
		public signal void show_all_requested ();
		int count;
		public TrayOverflowItem (int count)
		{
			Object (Prefs: new DockItemPreferences (), Text: _("%d more").printf (count));
			this.count = count;
		}
		public override bool can_be_removed () { return false; }
		protected override AnimationType on_hovered () { return AnimationType.LIGHTEN; }
		protected override AnimationType on_clicked (PopupButton button,
			Gdk.ModifierType mod, uint32 event_time)
		{
			if (button != PopupButton.LEFT)
				return AnimationType.NONE;
			show_all_requested ();
			return AnimationType.DARKEN;
		}
		protected override void draw_icon (Surface surface)
		{
			unowned Cairo.Context cr = surface.Context;
			cr.set_source_rgba (1, 1, 1, 0.9);
			cr.select_font_face ("Sans", Cairo.FontSlant.NORMAL, Cairo.FontWeight.BOLD);
			cr.set_font_size (int.min (surface.Width, surface.Height) * 0.26);
			var label = "+%d".printf (count);
			Cairo.TextExtents extents;
			cr.text_extents (label, out extents);
			cr.move_to ((surface.Width - extents.width) / 2.0 - extents.x_bearing,
				(surface.Height - extents.height) / 2.0 - extents.y_bearing);
			cr.show_text (label);
		}
	}
}
