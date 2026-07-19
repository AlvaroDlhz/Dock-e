// Native StatusNotifierItem model and floating background-applications panel.

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
		const string XAPP_PREFIX = "org.x.StatusIcon.";
		const string XAPP_ROOT = "/org/x/StatusIcon";
		const string OBJECT_MANAGER_IFACE = "org.freedesktop.DBus.ObjectManager";

		public signal void tray_changed ();
		public signal void expansion_changed (bool expanded);

		StatusNotifierWatcher? watcher;
		Gee.HashMap<string, TrayStatusItem> tray_items;
		Gee.HashMap<string, TrayStatusItem> xapp_items;
		DBusConnection? session_connection;
		Gdk.Pixbuf? closed_pixbuf;
		Gdk.Pixbuf? open_pixbuf;
		uint watcher_name_id = 0U;
		uint name_owner_subscription_id = 0U;
		uint interfaces_added_subscription_id = 0U;
		uint interfaces_removed_subscription_id = 0U;
		uint xapp_refresh_idle_id = 0U;
		uint reconciliation_timeout_id = 0U;
		uint reconciliation_tick = 0U;
		public bool Expanded { get; private set; default = false; }

		public TrayToggleItem ()
		{
			Object (Prefs: new DockItemPreferences (), Text: _("Background applications"));
			Button = PopupButton.LEFT;
			tray_items = new Gee.HashMap<string, TrayStatusItem> ();
			xapp_items = new Gee.HashMap<string, TrayStatusItem> ();
			load_state_icons ();
			connect_xapp_monitor ();
			watcher_name_id = Bus.watch_name (BusType.SESSION, "org.kde.StatusNotifierWatcher",
				BusNameWatcherFlags.NONE,
				(connection, name, owner) => connect_watcher (),
				(connection, name) => disconnect_watcher ());
			reconciliation_timeout_id = Timeout.add_seconds (2, reconcile_items);
		}

		~TrayToggleItem ()
		{
			if (watcher_name_id > 0U)
				Bus.unwatch_name (watcher_name_id);
			if (xapp_refresh_idle_id > 0U)
				Source.remove (xapp_refresh_idle_id);
			if (reconciliation_timeout_id > 0U)
				Source.remove (reconciliation_timeout_id);
			if (session_connection != null) {
				if (name_owner_subscription_id > 0U)
					session_connection.signal_unsubscribe (name_owner_subscription_id);
				if (interfaces_added_subscription_id > 0U)
					session_connection.signal_unsubscribe (interfaces_added_subscription_id);
				if (interfaces_removed_subscription_id > 0U)
					session_connection.signal_unsubscribe (interfaces_removed_subscription_id);
			}
		}

		bool reconcile_items ()
		{
			refresh ();
			// XApp emits reliable object-manager signals in the common case. This
			// slower fallback covers implementations that only change bus ownership.
			reconciliation_tick++;
			if (reconciliation_tick % 3U == 0U)
				schedule_xapp_refresh ();
			return true;
		}

		void connect_xapp_monitor ()
		{
			try {
				session_connection = Bus.get_sync (BusType.SESSION, null);
				name_owner_subscription_id = session_connection.signal_subscribe (
					"org.freedesktop.DBus", "org.freedesktop.DBus", "NameOwnerChanged",
					"/org/freedesktop/DBus", null, DBusSignalFlags.NONE,
					on_name_owner_changed);
				interfaces_added_subscription_id = session_connection.signal_subscribe (
					null, OBJECT_MANAGER_IFACE, "InterfacesAdded", XAPP_ROOT, null,
					DBusSignalFlags.NONE, () => schedule_xapp_refresh ());
				interfaces_removed_subscription_id = session_connection.signal_subscribe (
					null, OBJECT_MANAGER_IFACE, "InterfacesRemoved", XAPP_ROOT, null,
					DBusSignalFlags.NONE, () => schedule_xapp_refresh ());
				refresh_xapp_items ();
			} catch (Error e) {
				warning ("Unable to monitor XApp status icons: %s", e.message);
			}
		}

		void on_name_owner_changed (DBusConnection connection, string? sender_name,
			string object_path, string interface_name, string signal_name, Variant parameters)
		{
			var name = parameters.get_child_value (0).get_string ();
			if (name.has_prefix (XAPP_PREFIX))
				schedule_xapp_refresh ();
		}

		void schedule_xapp_refresh ()
		{
			if (xapp_refresh_idle_id > 0U)
				return;
			xapp_refresh_idle_id = Idle.add (() => {
				xapp_refresh_idle_id = 0U;
				refresh_xapp_items ();
				return false;
			});
		}

		void refresh_xapp_items ()
		{
			if (session_connection == null)
				return;
			var previous_count = xapp_items.size;
			var registered = new Gee.HashSet<string> ();
			try {
				var reply = session_connection.call_sync ("org.freedesktop.DBus",
					"/org/freedesktop/DBus", "org.freedesktop.DBus", "ListNames", null,
					new VariantType ("(as)"), DBusCallFlags.NONE, 2000, null);
				VariantIter names = reply.get_child_value (0).iterator ();
				string service;
				while (names.next ("s", out service)) {
					if (service.has_prefix (XAPP_PREFIX))
						load_xapp_service (service, registered);
				}
			} catch (Error e) {
				warning ("Unable to enumerate XApp status icons: %s", e.message);
				return;
			}

			bool membership_changed = xapp_items.size != previous_count;
			var iterator = xapp_items.map_iterator ();
			while (iterator.next ()) {
				if (!registered.contains (iterator.get_key ())) {
					iterator.unset ();
					membership_changed = true;
				}
			}
			if (membership_changed) {
				update_summary ();
				tray_changed ();
			}
		}

		void load_xapp_service (string service, Gee.HashSet<string> registered)
		{
			try {
				var reply = session_connection.call_sync (service, XAPP_ROOT,
					OBJECT_MANAGER_IFACE, "GetManagedObjects", null,
					new VariantType ("(a{oa{sa{sv}}})"), DBusCallFlags.NONE, 1000, null);
				VariantIter objects = reply.get_child_value (0).iterator ();
				string path;
				Variant interfaces;
				while (objects.next ("{o@a{sa{sv}}}", out path, out interfaces)) {
					if (interfaces.lookup_value ("org.x.StatusIcon", null) == null)
						continue;
					var key = "xapp:" + service + path;
					registered.add (key);
					if (xapp_items.has_key (key))
						continue;
					var item = new TrayStatusItem.xapp (service, path);
					item.changed.connect (() => {
						update_summary ();
						tray_changed ();
					});
					xapp_items[key] = item;
				}
			} catch (Error e) {
				// A status icon can disappear between ListNames and this call.
				debug ("Unable to inspect XApp status icon %s: %s", service, e.message);
			}
		}

		void load_state_icons ()
		{
			try {
				closed_pixbuf = new Gdk.Pixbuf.from_resource (
					G_RESOURCE_PATH + "/img/segundo-plano-closed.svg");
				open_pixbuf = new Gdk.Pixbuf.from_resource (
					G_RESOURCE_PATH + "/img/segundo-plano-open.svg");
			} catch (Error e) {
				warning ("Unable to load background-applications icons: %s", e.message);
			}
		}

		void connect_watcher ()
		{
			try {
				watcher = Bus.get_proxy_sync<StatusNotifierWatcher> (BusType.SESSION,
					"org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher");
				watcher.StatusNotifierItemRegistered.connect (() => refresh ());
				watcher.StatusNotifierItemUnregistered.connect (() => refresh ());
				watcher.notify["registered-status-notifier-items"].connect (() => refresh ());
				refresh ();
			} catch (Error e) {
				warning ("Status notifier watcher unavailable: %s", e.message);
				disconnect_watcher ();
			}
		}

		void disconnect_watcher ()
		{
			watcher = null;
			tray_items.clear ();
			update_summary ();
			tray_changed ();
		}

		void refresh ()
		{
			if (watcher == null)
				return;
			var registered = new Gee.HashSet<string> ();
			foreach (var identifier in identifiers ())
				registered.add (identifier);

			bool membership_changed = false;
			var iterator = tray_items.map_iterator ();
			while (iterator.next ()) {
				if (!registered.contains (iterator.get_key ())) {
					iterator.unset ();
					membership_changed = true;
				}
			}

			foreach (var identifier in registered) {
				if (tray_items.has_key (identifier))
					continue;
				try {
					var item = new TrayStatusItem (identifier);
					item.changed.connect (() => {
						update_summary ();
						tray_changed ();
					});
					tray_items[identifier] = item;
					membership_changed = true;
				} catch (Error e) {
					warning ("Unable to monitor tray item %s: %s", identifier, e.message);
				}
			}

			if (membership_changed) {
				update_summary ();
				tray_changed ();
			}
		}

		void update_summary ()
		{
			var item_count = applications ().size;
			Text = ngettext ("%d background application", "%d background applications",
				item_count).printf (item_count);
			Count = item_count;
			CountVisible = item_count > 0;
			Indicator = has_attention () ? IndicatorState.SINGLE : IndicatorState.NONE;
			reset_icon_buffer ();
		}

		bool has_attention ()
		{
			foreach (var item in tray_items.values)
				if (item.Status == "NeedsAttention")
					return true;
			foreach (var item in xapp_items.values)
				if (item.Visible && item.Status == "NeedsAttention")
					return true;
			return false;
		}

		string[] identifiers ()
		{
			return watcher == null ? new string[0] : watcher.RegisteredStatusNotifierItems;
		}

		public Gee.ArrayList<TrayStatusItem> applications ()
		{
			var result = new Gee.ArrayList<TrayStatusItem> ();
			result.add_all (tray_items.values);
			foreach (var item in xapp_items.values)
				if (item.Visible)
					result.add (item);
			result.sort ((a, b) => {
				var status_order = status_rank (a.Status) - status_rank (b.Status);
				return status_order != 0 ? status_order : a.Text.collate (b.Text);
			});
			return result;
		}

		static int status_rank (string status)
		{
			if (status == "NeedsAttention") return 0;
			if (status == "Active") return 1;
			return 2;
		}

		public void set_expanded (bool expanded)
		{
			if (Expanded == expanded)
				return;
			Expanded = expanded;
			reset_icon_buffer ();
			expansion_changed (Expanded);
		}

		public override bool can_be_removed () { return false; }
		protected override AnimationType on_hovered () { return AnimationType.LIGHTEN; }

		protected override AnimationType on_clicked (PopupButton button, Gdk.ModifierType mod,
			uint32 time)
		{
			if (button != PopupButton.LEFT)
				return AnimationType.NONE;
			unowned DockController? dock = get_dock ();
			if (dock != null)
				dock.background_apps.toggle (this);
			else
				set_expanded (!Expanded);
			return AnimationType.DARKEN;
		}

		protected override void draw_icon (Surface surface)
		{
			Gdk.Pixbuf? pixbuf = Expanded ? open_pixbuf : closed_pixbuf;
			if (pixbuf == null) {
				base.draw_icon (surface);
				return;
			}
			var size = (int) (int.min (surface.Width, surface.Height) * 0.58);
			var scaled = pixbuf.scale_simple (size, size, Gdk.InterpType.BILINEAR);
			unowned Cairo.Context cr = surface.Context;
			Gdk.cairo_set_source_pixbuf (cr, scaled,
				(surface.Width - size) / 2.0, (surface.Height - size) / 2.0);
			cr.paint_with_alpha (0.94);
		}
	}

	public class TrayStatusItem : DockItem
	{
		public signal void changed ();

		DBusProxy? proxy;
		string service;
		string menu_path = "";
#if HAVE_DBUSMENU
		DbusmenuGtk.Menu? cached_context_menu;
#endif
		bool item_is_menu = false;
		bool is_xapp = false;
		public string Identifier { get; private set; }
		public string Status { get; private set; default = "Active"; }
		public bool Visible { get; private set; default = true; }

		public TrayStatusItem (string identifier) throws Error
		{
			Object (Prefs: new DockItemPreferences ());
			Identifier = identifier;
			string parsed_service;
			string path;
			parse_identifier (identifier, out parsed_service, out path);
			service = parsed_service;
			proxy = new DBusProxy.for_bus_sync (BusType.SESSION, DBusProxyFlags.NONE,
				null, service, path, "org.kde.StatusNotifierItem");
			Button = PopupButton.LEFT | PopupButton.RIGHT;
			update_properties ();
			proxy.g_properties_changed.connect (() => update_properties ());
			proxy.g_signal.connect ((sender_name, signal_name, parameters) => {
				if (signal_name.has_prefix ("New"))
					update_properties ();
			});
		}

		public TrayStatusItem.xapp (string xapp_service, string path) throws Error
		{
			Object (Prefs: new DockItemPreferences ());
			Identifier = "xapp:" + xapp_service + path;
			service = xapp_service;
			is_xapp = true;
			proxy = new DBusProxy.for_bus_sync (BusType.SESSION, DBusProxyFlags.NONE,
				null, service, path, "org.x.StatusIcon");
			Button = PopupButton.LEFT | PopupButton.RIGHT;
			update_properties ();
			proxy.g_properties_changed.connect (() => update_properties ());
		}

		void update_properties ()
		{
			if (proxy == null)
				return;
			if (is_xapp) {
				update_xapp_properties ();
				return;
			}
			var title = proxy.get_cached_property ("Title");
			var id = proxy.get_cached_property ("Id");
			var new_status = proxy.get_cached_property ("Status");
			Status = new_status == null ? "Active" : new_status.get_string ();
			var icon = Status == "NeedsAttention"
				? proxy.get_cached_property ("AttentionIconName") : null;
			if (icon == null || icon.get_string () == "")
				icon = proxy.get_cached_property ("IconName");
			var is_menu = proxy.get_cached_property ("ItemIsMenu");
			item_is_menu = is_menu != null && is_menu.get_boolean ();
			var menu = proxy.get_cached_property ("Menu");
			var new_menu_path = menu == null ? "" : menu.get_string ();
			if (new_menu_path != menu_path) {
				menu_path = new_menu_path;
#if HAVE_DBUSMENU
				if (cached_context_menu != null)
					cached_context_menu.destroy ();
				cached_context_menu = menu_path == "" || menu_path == "/"
					? null : new DbusmenuGtk.Menu (service, menu_path);
#endif
			}
			var title_text = title == null ? "" : title.get_string ().strip ();
			var tooltip_text = status_notifier_tooltip_title ();
			var id_text = id == null ? "" : id.get_string ().strip ();
			Text = display_name (title_text != "" ? title_text
				: (tooltip_text != "" ? tooltip_text : id_text));
			Icon = icon == null || icon.get_string () == ""
				? "application-x-executable-symbolic" : icon.get_string ();
			Indicator = Status == "NeedsAttention" ? IndicatorState.SINGLE : IndicatorState.NONE;
			reset_icon_buffer ();
			changed ();
		}

		void update_xapp_properties ()
		{
			var name = string_property ("Name");
			var tooltip = string_property ("TooltipText");
			var icon = string_property ("IconName");
			var visible = proxy.get_cached_property ("Visible");
			Visible = visible == null || visible.get_boolean ();
			Status = "Active";
			Text = display_name (name != "" ? name : tooltip);
			Icon = icon != "" ? icon : "application-x-executable-symbolic";
			Indicator = IndicatorState.NONE;
			reset_icon_buffer ();
			changed ();
		}

		string string_property (string name)
		{
			var value = proxy.get_cached_property (name);
			return value == null ? "" : value.get_string ().strip ();
		}

		string status_notifier_tooltip_title ()
		{
			var tooltip = proxy.get_cached_property ("ToolTip");
			if (tooltip == null || tooltip.n_children () < 4)
				return "";
			var title = tooltip.get_child_value (2);
			var description = tooltip.get_child_value (3);
			var title_text = title.get_string ().strip ();
			return title_text != "" ? title_text : description.get_string ().strip ();
		}

		static string display_name (string candidate)
		{
			var result = candidate.strip ();
			if (result == "")
				return _("Background application");
			if (result.has_suffix (".py"))
				result = result.substring (0, result.length - 3);
			result = result.replace ("_", " ").replace ("-", " ");
			var readable = new StringBuilder ();
			unichar previous = 0;
			int offset = 0;
			unichar current;
			while (result.get_next_char (ref offset, out current)) {
				if (previous != 0 && current.isupper () && previous.islower ())
					readable.append_c (' ');
				readable.append_unichar (current);
				previous = current;
			}
			return readable.str.strip ();
		}

		public void activate_at (int x, int y)
		{
			call_coordinates (item_is_menu ? "ContextMenu" : "Activate", x, y);
		}

		public void context_menu_at (int x, int y)
		{
			call_coordinates ("ContextMenu", x, y);
		}

#if HAVE_DBUSMENU
		public unowned Gtk.Menu? get_context_menu ()
		{
			return cached_context_menu;
		}
#endif

		void call_coordinates (string method, int x, int y)
		{
			if (proxy == null)
				return;
			if (is_xapp) {
				call_xapp_button (method == "ContextMenu" ? 3U : 1U, x, y);
				return;
			}
			proxy.call.begin (method, new Variant ("(ii)", x, y), DBusCallFlags.NONE, -1,
				null, (obj, result) => {
					try {
						proxy.call.end (result);
					} catch (Error e) {
						warning ("Tray item %s could not run %s: %s", Identifier, method, e.message);
					}
				});
		}

		void call_xapp_button (uint button, int x, int y)
		{
			var time = Gtk.get_current_event_time ();
			var parameters = new Variant ("(iiuui)", x, y, button, time, 0);
			proxy.call.begin ("ButtonPress", parameters, DBusCallFlags.NONE, -1, null,
				(obj, result) => {
					try {
						proxy.call.end (result);
						proxy.call.begin ("ButtonRelease",
							new Variant ("(iiuui)", x, y, button, time, 0),
							DBusCallFlags.NONE, -1, null, (release_obj, release_result) => {
								try {
									proxy.call.end (release_result);
								} catch (Error e) {
									warning ("XApp item %s could not release button: %s",
										Identifier, e.message);
								}
							});
					} catch (Error e) {
						warning ("XApp item %s could not press button: %s", Identifier, e.message);
					}
				});
		}

		public override bool can_be_removed () { return false; }

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

	public class BackgroundAppsWindow : Gtk.Window
	{
		const int PANEL_WIDTH = 320;
		const int PANEL_HEIGHT = 360;
		const int PANEL_GAP = 10;

		unowned DockController controller;
		TrayToggleItem? current_item;
		Gtk.ListBox app_list;
		Gtk.Label count_label;
		Gee.ArrayList<TrayStatusItem> visible_apps;
		Gtk.Menu? context_menu;
		bool context_menu_open = false;
		ulong context_menu_deactivate_id = 0UL;
		int context_menu_x = 0;
		int context_menu_y = 0;
		uint context_menu_button = 0U;
		uint32 context_menu_time = 0U;
#if HAVE_DBUSMENU
		Dbusmenu.Client? context_menu_client;
		ulong context_layout_id = 0UL;
		ulong context_root_id = 0UL;
		uint context_popup_timeout_id = 0U;
#endif
		Gtk.CssProvider? css_provider;
		ulong tray_changed_id = 0UL;

		public BackgroundAppsWindow (DockController controller)
		{
			Object (type: Gtk.WindowType.TOPLEVEL);
			this.controller = controller;
			visible_apps = new Gee.ArrayList<TrayStatusItem> ();
			decorated = false;
			resizable = false;
			skip_taskbar_hint = true;
			skip_pager_hint = true;
			set_keep_above (true);
			type_hint = Gdk.WindowTypeHint.DIALOG;
			set_default_size (PANEL_WIDTH, PANEL_HEIGHT);
			set_size_request (PANEL_WIDTH, PANEL_HEIGHT);
			app_paintable = true;
			var visual = get_screen ().get_rgba_visual ();
			if (visual != null)
				set_visual (visual);
			get_style_context ().add_class ("plank-background-apps");
			Accessibility.describe (this, _("Background applications"));

			var card = new Gtk.Box (Gtk.Orientation.VERTICAL, 6);
			card.margin = 10;
			card.get_style_context ().add_class ("background-apps-card");
			var header = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
			header.get_style_context ().add_class ("background-apps-title");
			var title = new Gtk.Label (_("Background applications")) { xalign = 0.0f };
			title.get_style_context ().add_class ("background-apps-title-label");
			header.pack_start (title, true, true, 0);
			count_label = new Gtk.Label ("");
			count_label.get_style_context ().add_class ("background-apps-count");
			header.pack_end (count_label, false, false, 0);
			card.pack_start (header, false, false, 0);
			card.pack_start (new Gtk.Separator (Gtk.Orientation.HORIZONTAL), false, false, 0);

			app_list = new Gtk.ListBox ();
			app_list.selection_mode = Gtk.SelectionMode.SINGLE;
			app_list.activate_on_single_click = true;
			Accessibility.describe (app_list, _("Background application list"));
			app_list.row_activated.connect ((row) => activate_row (row));
			app_list.button_press_event.connect (handle_list_button);
			var scroll = new Gtk.ScrolledWindow (null, null);
			scroll.hscrollbar_policy = Gtk.PolicyType.NEVER;
			scroll.vscrollbar_policy = Gtk.PolicyType.AUTOMATIC;
			scroll.overlay_scrolling = true;
			scroll.get_style_context ().add_class ("background-apps-scroll");
			scroll.add (app_list);
			card.pack_start (scroll, true, true, 0);
			add (card);

			focus_out_event.connect (() => {
				if (!context_menu_open)
					dismiss ();
				return false;
			});
			key_press_event.connect ((event) => {
				Accessibility.set_keyboard_navigation (this, true);
				if (event.keyval == Gdk.Key.Escape) {
					dismiss ();
					return true;
				}
				return false;
			});
			button_press_event.connect (() => {
				Accessibility.set_keyboard_navigation (this, false);
				return false;
			});
			show.connect (() => {
				controller.hide_manager.ExternalMenuVisible = true;
				controller.hide_manager.update_hovered ();
			});
			hide.connect (() => {
				if (current_item != null)
					current_item.set_expanded (false);
				controller.hide_manager.ExternalMenuVisible = false;
				controller.hide_manager.update_hovered ();
			});
		}

		~BackgroundAppsWindow ()
		{
			disconnect_item ();
#if HAVE_DBUSMENU
			disconnect_context_menu_loader ();
#endif
			if (css_provider != null)
				Gtk.StyleContext.remove_provider_for_screen (get_screen (), css_provider);
		}

		public void toggle (TrayToggleItem item)
		{
			if (visible && current_item == item) {
				dismiss ();
				return;
			}
			disconnect_item ();
			current_item = item;
			tray_changed_id = item.tray_changed.connect (rebuild);
			item.set_expanded (true);
			controller.launcher.dismiss ();
			controller.status_panel.dismiss ();
			controller.window_previews.dismiss ();
			controller.workspace_previews.dismiss ();
			rebuild ();
			apply_theme ();
			opacity = 0.0;
			show_all ();
			present ();
			Idle.add (() => {
				position_over_item ();
				opacity = 1.0;
				app_list.child_focus (Gtk.DirectionType.TAB_FORWARD);
				return false;
			});
		}

		public void dismiss ()
		{
			if (current_item != null)
				current_item.set_expanded (false);
			if (visible)
				hide ();
		}

		void disconnect_item ()
		{
			if (current_item != null && tray_changed_id > 0UL)
				SignalHandler.disconnect (current_item, tray_changed_id);
			tray_changed_id = 0UL;
		}

		void rebuild ()
		{
			foreach (unowned Gtk.Widget child in app_list.get_children ())
				app_list.remove (child);
			visible_apps.clear ();
			if (current_item != null)
				visible_apps.add_all (current_item.applications ());
			count_label.label = "%d".printf (visible_apps.size);

			if (visible_apps.size == 0) {
				var empty = new Gtk.Label (_("No background applications"));
				empty.margin = 18;
				empty.get_style_context ().add_class ("background-apps-empty");
				app_list.add (empty);
			} else {
				foreach (var app in visible_apps)
					app_list.add (create_row (app));
			}
			app_list.show_all ();
		}

		Gtk.Widget create_row (TrayStatusItem app)
		{
			var row = new Gtk.ListBoxRow ();
			row.get_style_context ().add_class ("background-app-row");
			Accessibility.describe (row, app.Text, status_label (app.Status));
			var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10);
			box.margin = 7;
			Gtk.Image image;
			if (Path.is_absolute (app.Icon))
				image = new Gtk.Image.from_file (app.Icon);
			else
				image = new Gtk.Image.from_icon_name (app.Icon, Gtk.IconSize.DIALOG);
			image.pixel_size = 28;
			box.pack_start (image, false, false, 0);
			var labels = new Gtk.Box (Gtk.Orientation.VERTICAL, 2);
			var title = new Gtk.Label (app.Text) { xalign = 0.0f, ellipsize = Pango.EllipsizeMode.END };
			title.get_style_context ().add_class ("background-app-name");
			labels.pack_start (title, false, false, 0);
			var status = new Gtk.Label (status_label (app.Status)) { xalign = 0.0f };
			status.get_style_context ().add_class (app.Status == "NeedsAttention"
				? "background-app-attention" : "background-app-status");
			labels.pack_start (status, false, false, 0);
			box.pack_start (labels, true, true, 0);
			if (app.Status == "NeedsAttention") {
				var marker = new Gtk.Image.from_icon_name ("dialog-warning-symbolic", Gtk.IconSize.MENU);
				box.pack_end (marker, false, false, 0);
			}
			row.add (box);
			return row;
		}

		bool handle_list_button (Gdk.EventButton event)
		{
			Accessibility.set_keyboard_navigation (this, false);
			if (event.button != 3U)
				return false;
			var row = app_list.get_row_at_y ((int) event.y);
			if (row == null || row.get_index () < 0 || row.get_index () >= visible_apps.size)
				return false;
			app_list.select_row (row);
			show_context_menu_at (visible_apps[row.get_index ()], (int) event.x_root,
				(int) event.y_root, event.button, event.time);
			return true;
		}

		void show_context_menu_at (TrayStatusItem app, int root_x, int root_y,
			uint button, uint32 event_time)
		{
			close_current_context_menu ();
			context_menu_x = root_x;
			context_menu_y = root_y;
			context_menu_button = button;
			context_menu_time = event_time;
#if HAVE_DBUSMENU
			context_menu = app.get_context_menu ();
			if (context_menu != null) {
				context_menu_open = true;
				var opened_menu = context_menu;
				context_menu_deactivate_id = opened_menu.deactivate.connect (() => {
					context_menu_deactivated (opened_menu);
				});
				wait_for_context_menu_layout (context_menu);
				return;
			}
#endif
			// Older StatusNotifierItems may only implement the imperative method.
			// Keep this panel alive while the remote process creates its own menu.
			context_menu_open = true;
			app.context_menu_at (root_x, root_y);
			Timeout.add (750, () => {
				context_menu_open = false;
				if (visible)
					present ();
				return false;
			});
		}

		void close_current_context_menu ()
		{
#if HAVE_DBUSMENU
			disconnect_context_menu_loader ();
#endif
			if (context_menu != null && context_menu_deactivate_id > 0UL)
				SignalHandler.disconnect (context_menu, context_menu_deactivate_id);
			context_menu_deactivate_id = 0UL;
			if (context_menu != null)
				context_menu.popdown ();
			context_menu = null;
			context_menu_open = false;
		}

		void context_menu_deactivated (Gtk.Menu menu)
		{
			TrayStatusItem? next_app = null;
			int next_x = 0;
			int next_y = 0;
			uint next_button = 0U;
			uint32 next_time = 0U;
			double event_root_x = 0.0;
			double event_root_y = 0.0;
			var event = Gtk.get_current_event ();
			if (event != null && event.get_event_type () == Gdk.EventType.BUTTON_PRESS
				&& event.get_button (out next_button) && next_button == 3U
				&& event.get_root_coords (out event_root_x, out event_root_y)) {
				next_x = (int) event_root_x;
				next_y = (int) event_root_y;
				var row = row_at_root_position (next_x, next_y);
				if (row != null && row.get_index () >= 0
					&& row.get_index () < visible_apps.size) {
					next_app = visible_apps[row.get_index ()];
					next_time = event.get_time ();
					app_list.select_row (row);
				}
			}
#if HAVE_DBUSMENU
			disconnect_context_menu_loader ();
#endif
			if (context_menu_deactivate_id > 0UL)
				SignalHandler.disconnect (menu, context_menu_deactivate_id);
			context_menu_deactivate_id = 0UL;
			if (context_menu == menu)
				context_menu = null;
			context_menu_open = false;
			if (next_app != null) {
				var selected_app = next_app;
				Idle.add (() => {
					show_context_menu_at (selected_app, next_x, next_y,
						next_button, next_time);
					return false;
				});
			} else if (visible) {
				Idle.add (() => { present (); return false; });
			}
		}

		Gtk.ListBoxRow? row_at_root_position (int root_x, int root_y)
		{
			int window_x, window_y;
			get_position (out window_x, out window_y);
			int list_x, list_y;
			if (!app_list.translate_coordinates (this, 0, 0, out list_x, out list_y))
				return null;
			var local_x = root_x - window_x - list_x;
			var local_y = root_y - window_y - list_y;
			Gtk.Allocation allocation;
			app_list.get_allocation (out allocation);
			if (local_x < 0 || local_y < 0
				|| local_x >= allocation.width || local_y >= allocation.height)
				return null;
			return app_list.get_row_at_y (local_y);
		}

#if HAVE_DBUSMENU
		void wait_for_context_menu_layout (Gtk.Menu menu)
		{
			disconnect_context_menu_loader ();
			// Cached menus normally arrive here fully populated, so the common
			// path opens synchronously inside the original button event.
			if (popup_context_menu_if_ready (menu))
				return;
			var dbusmenu = menu as DbusmenuGtk.Menu;
			if (dbusmenu == null)
				return;
			context_menu_client = dbusmenu.get_client ();
			context_layout_id = context_menu_client.layout_updated.connect (() => {
				popup_context_menu_if_ready (menu);
			});
			context_root_id = context_menu_client.root_changed.connect (() => {
				popup_context_menu_if_ready (menu);
			});
			Idle.add (() => {
				popup_context_menu_if_ready (menu);
				return false;
			});
			context_popup_timeout_id = Timeout.add (1500, () => {
				context_popup_timeout_id = 0U;
				if (!popup_context_menu_if_ready (menu)) {
					warning ("Tray context menu did not provide a layout in time");
					disconnect_context_menu_loader ();
					context_menu_open = false;
					context_menu = null;
					if (visible)
						present ();
				}
				return false;
			});
		}

		bool popup_context_menu_if_ready (Gtk.Menu menu)
		{
			if (context_menu != menu || menu.get_children ().length () == 0)
				return false;
			disconnect_context_menu_loader ();
			menu.show_all ();
			menu.popup (null, null, (Gtk.MenuPositionFunc) position_context_menu,
				context_menu_button, context_menu_time);
			return true;
		}

		[CCode (instance_pos = -1)]
		void position_context_menu (Gtk.Menu menu, ref int x, ref int y, out bool push_in)
		{
			x = context_menu_x;
			y = context_menu_y;
			push_in = true;
		}

		void disconnect_context_menu_loader ()
		{
			if (context_menu_client != null && context_layout_id > 0UL)
				SignalHandler.disconnect (context_menu_client, context_layout_id);
			if (context_menu_client != null && context_root_id > 0UL)
				SignalHandler.disconnect (context_menu_client, context_root_id);
			if (context_popup_timeout_id > 0U)
				Source.remove (context_popup_timeout_id);
			context_menu_client = null;
			context_layout_id = 0UL;
			context_root_id = 0UL;
			context_popup_timeout_id = 0U;
		}
#endif

		void activate_row (Gtk.ListBoxRow row)
		{
			if (row.get_index () < 0 || row.get_index () >= visible_apps.size)
				return;
			int x, y;
			get_position (out x, out y);
			visible_apps[row.get_index ()].activate_at (x + PANEL_WIDTH / 2, y + 30);
			dismiss ();
		}

		string status_label (string status)
		{
			if (status == "NeedsAttention") return _("Needs attention");
			if (status == "Active") return _("Active");
			return _("In the background");
		}

		void position_over_item ()
		{
			if (current_item == null)
				return;
			var item = controller.position_manager.get_screen_region_for_item (current_item);
			var screen = get_screen ();
			var monitor = screen.get_monitor_at_point (item.x, item.y);
			var workarea = screen.get_monitor_workarea (monitor);
			int x, y;
			controller.position_manager.get_popup_position (item, PANEL_WIDTH, PANEL_HEIGHT,
				PANEL_GAP, workarea, out x, out y);
			move (x, y);
		}

		void apply_theme ()
		{
			var color = controller.renderer.theme.FillStartColor;
			var css = ".plank-background-apps { background: transparent; }";
			css += ".plank-background-apps .background-apps-card { background-color: rgb(%d,%d,%d); border: 1px solid rgba(255,255,255,0.10); border-radius: 12px; padding: 7px; }"
				.printf ((int)(color.red*255), (int)(color.green*255), (int)(color.blue*255));
			css += ".plank-background-apps .background-apps-title { color: white; padding: 5px 7px; }";
			css += ".plank-background-apps .background-apps-title-label { font-weight: bold; font-size: 15px; }";
			css += ".plank-background-apps .background-apps-count { color: white; background-color: rgba(255,255,255,0.12); border-radius: 9px; padding: 2px 7px; }";
			css += ".plank-background-apps list, .plank-background-apps row, .plank-background-apps .background-apps-scroll { background: transparent; border: none; box-shadow: none; }";
			css += ".plank-background-apps row { color: white; border-radius: 9px; margin: 2px 1px; }";
			css += ".plank-background-apps row:hover, .plank-background-apps row:selected { background-color: rgba(255,255,255,0.10); }";
			css += ".plank-background-apps .background-app-name { color: white; font-weight: bold; }";
			css += ".plank-background-apps .background-app-status, .plank-background-apps .background-apps-empty { color: rgba(255,255,255,0.58); }";
			css += ".plank-background-apps .background-app-attention { color: rgb(255,190,80); }";
			css += ".plank-background-apps separator { background-color: rgba(255,255,255,0.10); }";
			css += ".plank-background-apps scrollbar { background: transparent; border: none; }";
			css += ".plank-background-apps scrollbar slider { min-width: 4px; min-height: 28px; background-color: rgba(255,255,255,0.18); border-radius: 4px; }";
			css += ".plank-background-apps.keyboard-navigation row:focus { box-shadow: 0 0 0 2px rgba(115,210,22,0.85); }";
			if (css_provider != null)
				Gtk.StyleContext.remove_provider_for_screen (get_screen (), css_provider);
			css_provider = new Gtk.CssProvider ();
			try {
				css_provider.load_from_data (css);
			} catch (Error e) {
				warning ("Background applications CSS: %s", e.message);
			}
			Gtk.StyleContext.add_provider_for_screen (get_screen (), css_provider,
				Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
		}
	}

	// Kept for ABI/source compatibility with the initial inline tray implementation.
	public class TrayOverflowItem : DockItem
	{
		public TrayOverflowItem (int count)
		{
			Object (Prefs: new DockItemPreferences (), Text: _("%d more").printf (count));
		}
		public override bool can_be_removed () { return false; }
	}
}
