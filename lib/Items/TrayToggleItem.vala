// Native StatusNotifierItem model and floating background-applications panel.

namespace Plank
{
	[DBus (name = "org.kde.StatusNotifierWatcher")]
	interface StatusNotifierWatcher : Object
	{
		public abstract string[] RegisteredStatusNotifierItems { owned get; }
		public abstract async void RegisterStatusNotifierHost (string service) throws Error;
		public signal void StatusNotifierItemRegistered (string item);
		public signal void StatusNotifierItemUnregistered (string item);
	}

	/**
	 * What Dock-E is to the StatusNotifierWatcher of the session.
	 */
	public enum TrayWatcherRole
	{
		/**
		 * Nobody keeps the list yet. Dock-E gives the desktop a moment to
		 * start its own before keeping it itself.
		 */
		WAITING,
		/**
		 * Dock-E asked for the name and waits for the answer.
		 */
		CLAIMING,
		/**
		 * Dock-E keeps the list, and lets the desktop take it over.
		 */
		OWNER,
		/**
		 * The desktop (Plasma, xapp-sn-watcher, the panel...) keeps the
		 * list and Dock-E only shows what is in it, like any other host.
		 */
		HOST
	}

	/**
	 * Decides whether Dock-E keeps the StatusNotifierWatcher or leaves it to
	 * the desktop.
	 *
	 * There can only be one watcher in a session. The one of the desktop
	 * comes first: Dock-E never takes the name from it, waits a moment at
	 * start in case it is about to appear, and gives the name up whenever it
	 * asks for it. Only where nothing else keeps the list does Dock-E keep
	 * it, so that the applications still have somewhere to register.
	 *
	 * This only decides. Asking the bus and timing are left to the caller,
	 * so that the decisions can be tested without a bus.
	 */
	public class TrayWatcherArbiter : Object
	{
		/**
		 * How long the name has to be free before Dock-E takes it.
		 */
		public const uint CLAIM_DELAY_MS = 3000U;

		/**
		 * Flags to ask for the name with: the desktop may replace Dock-E, and
		 * Dock-E does not wait in line to get it back behind the desktop's
		 * back, it decides again when the name is free.
		 */
		public const BusNameOwnerFlags OWNER_FLAGS =
			BusNameOwnerFlags.ALLOW_REPLACEMENT | BusNameOwnerFlags.DO_NOT_QUEUE;

		public TrayWatcherRole role { get; private set; default = TrayWatcherRole.WAITING; }

		// Whether Dock-E asked for the name and has not given it up since
		bool asking = false;

		/**
		 * The name is free: whether a claim has to be scheduled.
		 */
		public bool name_vanished ()
		{
			if (role == TrayWatcherRole.CLAIMING || role == TrayWatcherRole.OWNER)
				return false;
			role = TrayWatcherRole.WAITING;
			return true;
		}

		/**
		 * Somebody owns the name. When it is not Dock-E, Dock-E is a host.
		 */
		public void name_appeared (bool owned_by_us)
		{
			if (owned_by_us)
				return;
			role = TrayWatcherRole.HOST;
		}

		/**
		 * The scheduled claim is due: whether to ask for the name now.
		 *
		 * @param name_has_owner whether somebody took the name in the meantime
		 */
		public bool claim_due (bool name_has_owner)
		{
			if (role != TrayWatcherRole.WAITING)
				return false;
			if (name_has_owner) {
				role = TrayWatcherRole.HOST;
				return false;
			}
			role = TrayWatcherRole.CLAIMING;
			asking = true;
			return true;
		}

		public void name_acquired ()
		{
			role = TrayWatcherRole.OWNER;
		}

		/**
		 * Dock-E did not get the name, or the desktop replaced it.
		 *
		 * @return whether Dock-E has to stop asking for the name
		 */
		public bool name_lost ()
		{
			var was_asking = asking;
			asking = false;
			role = TrayWatcherRole.HOST;
			return was_asking;
		}

		/**
		 * Whether an XApp status icon only mirrors a StatusNotifierItem.
		 *
		 * xapp-sn-watcher, the watcher of Cinnamon and MATE, shows every
		 * StatusNotifierItem as an XApp status icon of its own process.
		 * Dock-E shows the item itself, so the mirror is left out.
		 *
		 * @param icon_pid the process that owns the XApp icon, 0 if unknown
		 * @param watcher_pid the process of a watcher Dock-E does not keep, 0 if none
		 */
		public static bool is_mirrored_icon (uint32 icon_pid, uint32 watcher_pid)
		{
			return watcher_pid != 0U && icon_pid == watcher_pid;
		}
	}

	public class TrayToggleItem : DockItem
	{
		const string XAPP_PREFIX = "org.x.StatusIcon.";
		const string XAPP_ROOT = "/org/x/StatusIcon";
		const string OBJECT_MANAGER_IFACE = "org.freedesktop.DBus.ObjectManager";
		const string WATCHER_NAME = "org.kde.StatusNotifierWatcher";
		const string WATCHER_PATH = "/StatusNotifierWatcher";

		public signal void tray_changed ();
		public signal void expansion_changed (bool expanded);

		StatusNotifierWatcher? watcher;
		LocalStatusNotifierWatcher? local_watcher;
		Gee.HashMap<string, TrayStatusItem> tray_items;
		Gee.HashMap<string, TrayStatusItem> xapp_items;
		DBusConnection? session_connection;
		DBusConnection? watcher_connection;
		Gdk.Pixbuf? closed_pixbuf;
		Gdk.Pixbuf? open_pixbuf;
		TrayWatcherArbiter arbiter;
		bool owns_watcher = false;
		bool destroying = false;
		uint watcher_name_id = 0U;
		uint watcher_watch_id = 0U;
		uint claim_timeout_id = 0U;
		uint host_name_id = 0U;
		string host_name;
		// The process of a watcher Dock-E does not keep, to leave out its mirrors
		uint32 external_watcher_pid = 0U;
		uint name_owner_subscription_id = 0U;
		uint interfaces_added_subscription_id = 0U;
		uint interfaces_removed_subscription_id = 0U;
		uint xapp_refresh_idle_id = 0U;
		public bool Expanded { get; private set; default = false; }

		public TrayToggleItem ()
		{
			Object (Prefs: new DockItemPreferences (), Text: _("Background applications"));
			Button = PopupButton.LEFT;
			tray_items = new Gee.HashMap<string, TrayStatusItem> ();
			xapp_items = new Gee.HashMap<string, TrayStatusItem> ();
			load_state_icons ();
			arbiter = new TrayWatcherArbiter ();
			host_name = "org.kde.StatusNotifierHost-%d-dock-e".printf ((int) Posix.getpid ());
			host_name_id = Bus.own_name (BusType.SESSION, host_name, BusNameOwnerFlags.NONE,
				null, null, null);
			connect_xapp_monitor ();
			watch_watcher_name ();
		}

		~TrayToggleItem ()
		{
			destroying = true;
			if (watcher_name_id > 0U)
				Bus.unown_name (watcher_name_id);
			if (watcher_watch_id > 0U)
				Bus.unwatch_name (watcher_watch_id);
			if (claim_timeout_id > 0U)
				Source.remove (claim_timeout_id);
			if (host_name_id > 0U)
				Bus.unown_name (host_name_id);
			unregister_local_watcher ();
			if (xapp_refresh_idle_id > 0U)
				Source.remove (xapp_refresh_idle_id);
			if (session_connection != null) {
				if (name_owner_subscription_id > 0U)
					session_connection.signal_unsubscribe (name_owner_subscription_id);
				if (interfaces_added_subscription_id > 0U)
					session_connection.signal_unsubscribe (interfaces_added_subscription_id);
				if (interfaces_removed_subscription_id > 0U)
					session_connection.signal_unsubscribe (interfaces_removed_subscription_id);
			}
		}

		/**
		 * Compares the known items with what is registered right now.
		 *
		 * Registrations, removals and bus ownership all arrive as signals, so
		 * nothing is polled while idle. This only covers an implementation
		 * which misses one of them, when the list is about to be looked at.
		 */
		void reconcile_items ()
		{
			refresh ();
			schedule_xapp_refresh ();
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
			if (external_watcher_pid != 0U
				&& TrayWatcherArbiter.is_mirrored_icon (pid_of (service), external_watcher_pid))
				return;
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

		/**
		 * Follows who keeps the list of StatusNotifierItems, see TrayWatcherArbiter.
		 */
		void watch_watcher_name ()
		{
			watcher_watch_id = Bus.watch_name (BusType.SESSION, WATCHER_NAME,
				BusNameWatcherFlags.NONE,
				(connection, name, owner) => on_watcher_appeared (connection, owner),
				(connection, name) => on_watcher_vanished ());
		}

		void on_watcher_appeared (DBusConnection connection, string owner)
		{
			if (destroying)
				return;
			var owned_by_us = owner == connection.get_unique_name ();
			arbiter.name_appeared (owned_by_us);
			if (owned_by_us)
				return;
			cancel_claim ();
			// The desktop may replace Dock-E before Dock-E hears it lost the name
			drop_local_watcher ();
			connect_watcher ();
		}

		void on_watcher_vanished ()
		{
			if (destroying)
				return;
			if (watcher != null)
				disconnect_watcher ();
			if (!arbiter.name_vanished () || claim_timeout_id > 0U)
				return;
			claim_timeout_id = Timeout.add (TrayWatcherArbiter.CLAIM_DELAY_MS, () => {
				claim_timeout_id = 0U;
				if (arbiter.claim_due (watcher != null))
					own_watcher ();
				return false;
			});
		}

		void cancel_claim ()
		{
			if (claim_timeout_id > 0U) {
				Source.remove (claim_timeout_id);
				claim_timeout_id = 0U;
			}
		}

		void own_watcher ()
		{
			if (watcher_name_id > 0U)
				return;
			watcher_name_id = Bus.own_name (BusType.SESSION, WATCHER_NAME,
				TrayWatcherArbiter.OWNER_FLAGS,
				(connection, name) => {},
				(connection, name) => on_watcher_name_acquired (connection, name),
				(connection, name) => on_watcher_name_lost (connection, name));
		}

		void on_watcher_name_acquired (DBusConnection connection, string name)
		{
			if (destroying)
				return;
			arbiter.name_acquired ();
			owns_watcher = true;
			watcher = null;
			external_watcher_pid = 0U;
			watcher_connection = connection;
			local_watcher = new LocalStatusNotifierWatcher (connection);
			try {
				local_watcher.registration_id =
					connection.register_object<LocalStatusNotifierWatcher> (WATCHER_PATH, local_watcher);
			} catch (IOError e) {
				warning ("Unable to export the status notifier watcher: %s", e.message);
			}
			local_watcher.status_notifier_item_registered.connect (() => refresh ());
			local_watcher.status_notifier_item_unregistered.connect (() => refresh ());
			debug ("Dock-E is now the StatusNotifierWatcher");
			refresh ();
			schedule_xapp_refresh ();
		}

		void on_watcher_name_lost (DBusConnection connection, string name)
		{
			if (destroying)
				return;
			drop_local_watcher ();
			// Stop asking, the name watch tells when it is free again
			if (arbiter.name_lost () && watcher_name_id > 0U) {
				Bus.unown_name (watcher_name_id);
				watcher_name_id = 0U;
			}
		}

		void drop_local_watcher ()
		{
			if (!owns_watcher)
				return;
			owns_watcher = false;
			unregister_local_watcher ();
			tray_items.clear ();
			update_summary ();
			tray_changed ();
			debug ("The desktop took over the StatusNotifierWatcher, Dock-E is now a host");
		}

		void unregister_local_watcher ()
		{
			if (local_watcher != null && watcher_connection != null
				&& local_watcher.registration_id > 0U) {
				watcher_connection.unregister_object (local_watcher.registration_id);
				local_watcher.registration_id = 0U;
			}
			local_watcher = null;
			watcher_connection = null;
		}

		/**
		 * Shows what the desktop's watcher lists, as one more host.
		 */
		void connect_watcher ()
		{
			try {
				watcher = Bus.get_proxy_sync<StatusNotifierWatcher> (BusType.SESSION,
					WATCHER_NAME, WATCHER_PATH);
				watcher.StatusNotifierItemRegistered.connect (() => refresh ());
				watcher.StatusNotifierItemUnregistered.connect (() => refresh ());
				watcher.notify["registered-status-notifier-items"].connect (() => refresh ());
				// Applications only use StatusNotifierItem where a host says it is there
				watcher.RegisterStatusNotifierHost.begin (host_name, (obj, res) => {
					try {
						((StatusNotifierWatcher) obj).RegisterStatusNotifierHost.end (res);
					} catch (Error e) {
						debug ("Unable to register as status notifier host: %s", e.message);
					}
				});
				external_watcher_pid = pid_of (WATCHER_NAME);
				debug ("Dock-E is a host of the desktop's StatusNotifierWatcher");
				refresh ();
				schedule_xapp_refresh ();
			} catch (Error e) {
				warning ("Status notifier watcher unavailable: %s", e.message);
				disconnect_watcher ();
			}
		}

		uint32 pid_of (string name)
		{
			if (session_connection == null)
				return 0U;
			try {
				var reply = session_connection.call_sync ("org.freedesktop.DBus",
					"/org/freedesktop/DBus", "org.freedesktop.DBus", "GetConnectionUnixProcessID",
					new Variant ("(s)", name), new VariantType ("(u)"), DBusCallFlags.NONE, 1000, null);
				return reply.get_child_value (0).get_uint32 ();
			} catch (Error e) {
				return 0U;
			}
		}

		void disconnect_watcher ()
		{
			watcher = null;
			if (external_watcher_pid != 0U) {
				external_watcher_pid = 0U;
				schedule_xapp_refresh ();
			}
			tray_items.clear ();
			update_summary ();
			tray_changed ();
		}

		void refresh ()
		{
			if (watcher == null && local_watcher == null)
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
			if (local_watcher != null)
				return local_watcher.registered_status_notifier_items;
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
			if (expanded)
				reconcile_items ();
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

	// In-process implementation of the StatusNotifierWatcher D-Bus service.
	// Dock-E claims this role when no other watcher (Plasma, xapp-sn-watcher,
	// ...) is running, so plain StatusNotifierItem clients register and show up.
	[DBus (name = "org.kde.StatusNotifierWatcher")]
	class LocalStatusNotifierWatcher : GLib.Object
	{
		const string ITEM_INTERFACE = "org.kde.StatusNotifierItem";

		// Some clients (Qt) call RegisterStatusNotifierItem just before the item
		// object becomes introspectable, so retry the probe a few times.
		const uint VALIDATION_RETRY_MS = 150U;
		const uint MAX_VALIDATION_ATTEMPTS = 10U;

		Gee.HashSet<string> registered_items;
		DBusConnection connection;
		uint name_owner_changed_id = 0U;

		// Not a D-Bus member (public fields are never exported); owned by TrayToggleItem.
		public uint registration_id = 0U;

		public signal void status_notifier_item_registered (string item);
		public signal void status_notifier_item_unregistered (string item);
		public signal void status_notifier_host_registered ();
		public signal void status_notifier_host_unregistered ();

		public LocalStatusNotifierWatcher (DBusConnection connection)
		{
			this.connection = connection;
			registered_items = new Gee.HashSet<string> ();
			name_owner_changed_id = connection.signal_subscribe ("org.freedesktop.DBus",
				"org.freedesktop.DBus", "NameOwnerChanged", "/org/freedesktop/DBus", null,
				DBusSignalFlags.NONE, on_name_owner_changed);
		}

		~LocalStatusNotifierWatcher ()
		{
			if (connection != null && name_owner_changed_id > 0U)
				connection.signal_unsubscribe (name_owner_changed_id);
		}

		public string[] registered_status_notifier_items {
			owned get {
				var result = new string[registered_items.size];
				var index = 0;
				foreach (var item in registered_items)
					result[index++] = item;
				return result;
			}
		}

		public bool is_status_notifier_host_registered {
			get { return true; }
		}

		public int protocol_version {
			get { return 0; }
		}

		public void register_status_notifier_item (string service_or_path, GLib.BusName sender)
		{
			string service;
			string path;
			if (service_or_path.has_prefix ("/")) {
				service = sender;
				path = service_or_path;
			} else {
				service = service_or_path;
				path = "/StatusNotifierItem";
			}

			if (service == "")
				return;
			var identifier = service + path;
			if (registered_items.contains (identifier))
				return;

			// Defer the synchronous validity probe out of the method-call
			// dispatch so the bus reply can be processed safely.
			var probe_service = service;
			var probe_path = path;
			Idle.add (() => {
				validate_with_retry (probe_service, probe_path, 0U);
				return false;
			});
		}

		public void register_status_notifier_host (string service, GLib.BusName sender)
		{
			status_notifier_host_registered ();
		}

		void validate_with_retry (string service, string path, uint attempt)
		{
			var identifier = service + path;
			if (registered_items.contains (identifier))
				return;
			if (is_valid_item (service, path)) {
				registered_items.add (identifier);
				status_notifier_item_registered (identifier);
				return;
			}
			if (attempt >= MAX_VALIDATION_ATTEMPTS)
				return;
			Timeout.add (VALIDATION_RETRY_MS, () => {
				validate_with_retry (service, path, attempt + 1);
				return false;
			});
		}

		bool is_valid_item (string service, string path)
		{
			try {
				var proxy = new DBusProxy.for_bus_sync (BusType.SESSION, DBusProxyFlags.NONE,
					null, service, path, ITEM_INTERFACE);
				if (proxy.g_name_owner == null)
					return false;
				return proxy.get_cached_property ("Id") != null
					|| proxy.get_cached_property ("Status") != null
					|| proxy.get_cached_property ("IconName") != null;
			} catch (Error e) {
				debug ("Rejecting status notifier item %s%s: %s", service, path, e.message);
				return false;
			}
		}

		[CCode (instance_pos = -1)]
		void on_name_owner_changed (DBusConnection connection, string? sender_name,
			string object_path, string interface_name, string signal_name, Variant parameters)
		{
			var name = parameters.get_child_value (0).get_string ();
			var new_owner = parameters.get_child_value (2).get_string ();
			if (new_owner != "")
				return;

			var prefix = name + "/";
			var removed = new Gee.ArrayList<string> ();
			foreach (var item in registered_items)
				if (item.has_prefix (prefix))
					removed.add (item);

			foreach (var item in removed) {
				registered_items.remove (item);
				status_notifier_item_unregistered (item);
			}
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
		/**
		 * What the application says about itself at the moment, if anything.
		 */
		public string Detail { get; private set; default = ""; }
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
			Detail = status_notifier_detail ();
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
			Detail = distinct_detail (tooltip);
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

		/**
		 * The part of the tooltip which says more than the name does.
		 */
		string status_notifier_detail ()
		{
			var tooltip = proxy.get_cached_property ("ToolTip");
			if (tooltip == null || tooltip.n_children () < 4)
				return "";
			var description = distinct_detail (tooltip.get_child_value (3).get_string ());
			if (description != "")
				return description;
			return distinct_detail (tooltip.get_child_value (2).get_string ());
		}

		/**
		 * A text as one plain line, or nothing if it only repeats the name.
		 */
		string distinct_detail (string text)
		{
			var plain = text;
			try {
				// Tooltips may carry markup
				plain = new Regex ("<[^>]*>").replace (text, -1, 0, "");
			} catch (RegexError e) {
				plain = text;
			}
			// Keep the lines in a variable: taking one out of a temporary
			// list leaves a text which is already freed
			var lines = plain.strip ().split ("\n");
			plain = lines.length > 0 ? lines[0].strip () : "";
			if (plain == "" || plain.casefold () == Text.casefold ())
				return "";
			return plain;
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
		// The list grows with its rows up to this height, then it scrolls
		const int MAX_LIST_HEIGHT = 376;
		const int PANEL_MARGIN = 10;
		const int PANEL_GAP = 10;

		unowned DockController controller;
		TrayToggleItem? current_item;
		Gtk.ListBox app_list;
		Gtk.SearchEntry search_entry;
		Gtk.Label count_label;
		Gee.ArrayList<TrayStatusItem> applications;
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
		ulong tray_changed_id = 0UL;
		// Rows are kept while their application is listed, so a change
		// neither loses the selection nor makes the list flicker
		Gee.HashMap<TrayStatusItem, BackgroundAppRow> rows;
		ListSelectionGlide selection_glide;
		WindowTransition transition;
		// The point the panel grows out of, which is as near to its button as it gets
		double growth_x = 0.0;
		double growth_y = 0.0;

		public BackgroundAppsWindow (DockController controller)
		{
			Object (type: Gtk.WindowType.TOPLEVEL);
			this.controller = controller;
			applications = new Gee.ArrayList<TrayStatusItem> ();
			visible_apps = new Gee.ArrayList<TrayStatusItem> ();
			rows = new Gee.HashMap<TrayStatusItem, BackgroundAppRow> ();
			transition = new WindowTransition (this);
			decorated = false;
			resizable = false;
			skip_taskbar_hint = true;
			skip_pager_hint = true;
			set_keep_above (true);
			type_hint = Gdk.WindowTypeHint.DIALOG;
			// Not being resizable, the window is as high as its content asks for
			set_size_request (PANEL_WIDTH, -1);
			app_paintable = true;
			var visual = get_screen ().get_rgba_visual ();
			if (visual != null)
				set_visual (visual);
			get_style_context ().add_class ("plank-background-apps");
			Accessibility.describe (this, _("Background applications"));

			var card = new Gtk.Box (Gtk.Orientation.VERTICAL, 4);
			card.margin = PANEL_MARGIN;
			card.get_style_context ().add_class ("background-apps-card");
			var header = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 8);
			header.get_style_context ().add_class ("background-apps-title");
			var title = new Gtk.Label (_("Background applications")) { xalign = 0.0f };
			title.get_style_context ().add_class ("background-apps-title-label");
			header.pack_start (title, true, true, 0);
			count_label = new Gtk.Label ("");
			count_label.get_style_context ().add_class ("background-apps-count");
			Accessibility.describe (count_label, _("Background application count"));
			header.pack_end (count_label, false, false, 0);
			card.pack_start (header, false, false, 0);

			search_entry = new Gtk.SearchEntry ();
			search_entry.placeholder_text = _("Search background applications");
			Accessibility.describe (search_entry, _("Search background applications"));
			search_entry.no_show_all = true;
			search_entry.changed.connect (rebuild);
			card.pack_start (search_entry, false, false, 0);

			app_list = new Gtk.ListBox ();
			app_list.selection_mode = Gtk.SelectionMode.SINGLE;
			app_list.activate_on_single_click = true;
			Accessibility.describe (app_list, _("Background application list"));
			app_list.row_activated.connect ((row) => activate_row (row));
			app_list.button_press_event.connect (handle_list_button);
			selection_glide = new ListSelectionGlide (app_list);
			selection_glide.inset_x = 2;
			var scroll = new Gtk.ScrolledWindow (null, null);
			scroll.hscrollbar_policy = Gtk.PolicyType.NEVER;
			scroll.vscrollbar_policy = Gtk.PolicyType.AUTOMATIC;
			scroll.overlay_scrolling = true;
			scroll.propagate_natural_height = true;
			scroll.max_content_height = MAX_LIST_HEIGHT;
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
				switch (event.keyval) {
				case Gdk.Key.Escape:
					if (search_entry.text != "") {
						search_entry.text = "";
						search_entry.grab_focus ();
					} else {
						dismiss ();
					}
					return true;
				case Gdk.Key.Up:
					move_selection (-1);
					return true;
				case Gdk.Key.Down:
					move_selection (1);
					return true;
				case Gdk.Key.Home:
					move_selection_to (0);
					return true;
				case Gdk.Key.End:
					move_selection_to (visible_apps.size - 1);
					return true;
				case Gdk.Key.Return:
				case Gdk.Key.KP_Enter:
					var row = app_list.get_selected_row ();
					if (row != null)
						activate_row (row);
					return row != null;
				case Gdk.Key.F10:
					if ((event.state & Gdk.ModifierType.SHIFT_MASK) != 0) {
						show_selected_context_menu ();
						return true;
					}
					return false;
				case Gdk.Key.Menu:
					show_selected_context_menu ();
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

			controller.window_previews.dismiss ();
			controller.workspace_previews.dismiss ();
			rebuild ();
			apply_theme ();
			selection_glide.snap ();
			transition.jump_to (0.0);
			show_all ();
			present ();
			Idle.add (() => {
				position_over_item ();
				transition.animate_to (1.0,
					Motion.duration (controller.prefs, Motion.POPUP_OPEN_TIME), false, true);
				app_list.child_focus (Gtk.DirectionType.TAB_FORWARD);
				return false;
			});
		}

		public void dismiss ()
		{
			if (current_item != null)
				current_item.set_expanded (false);
			if (visible)
				transition.animate_to (0.0,
					Motion.duration (controller.prefs, Motion.POPUP_CLOSE_TIME), true);
		}

		public override bool draw (Cairo.Context cr)
		{
			// The window itself stays put. Its content grows out of its button
			// on the dock while appearing and shrinks back into it while leaving.
			if (transition.progress != 1.0 && Motion.movement_enabled (controller.prefs)) {
				var scale = Motion.POPUP_SCALE + (1.0 - Motion.POPUP_SCALE) * transition.progress;
				cr.translate (growth_x, growth_y);
				cr.scale (scale, scale);
				cr.translate (-growth_x, -growth_y);
			}
			return base.draw (cr);
		}

		void disconnect_item ()
		{
			if (current_item != null && tray_changed_id > 0UL)
				SignalHandler.disconnect (current_item, tray_changed_id);
			tray_changed_id = 0UL;
		}

		void rebuild ()
		{
			applications.clear ();
			if (current_item != null)
				applications.add_all (current_item.applications ());
			count_label.label = "%d".printf (applications.size);
			count_label.visible = applications.size > 0;
			search_entry.visible = applications.size > 8;
			if (applications.size <= 8 && search_entry.text != "")
				search_entry.text = "";

			var query = search_entry.text.strip ().down ();
			var shown = new Gee.ArrayList<TrayStatusItem> ();
			foreach (var app in applications) {
				if (query == "" || app.Text.down ().contains (query))
					shown.add (app);
			}

			// The same applications in the same order only need their rows brought up to date
			var same = shown.size > 0 && shown.size == visible_apps.size;
			for (var i = 0; same && i < shown.size; i++)
				same = shown[i] == visible_apps[i] && rows.has_key (shown[i]);
			if (same) {
				foreach (var app in shown)
					rows[app].update ();
				return;
			}

			TrayStatusItem? selected_app = null;
			var selected_row = app_list.get_selected_row ();
			if (selected_row != null && selected_row.get_index () >= 0
				&& selected_row.get_index () < visible_apps.size)
				selected_app = visible_apps[selected_row.get_index ()];

			selection_glide.snap ();
			// A row taken out while selected would still claim to be selected
			// when it returns, and the list would refuse to select it again
			app_list.unselect_all ();
			foreach (unowned Gtk.Widget child in app_list.get_children ())
				app_list.remove (child);
			visible_apps.clear ();
			visible_apps.add_all (shown);

			// Forget the rows of applications which are gone
			var listed = new Gee.HashSet<TrayStatusItem> ();
			listed.add_all (applications);
			var rows_it = rows.map_iterator ();
			while (rows_it.next ())
				if (!listed.contains (rows_it.get_key ()))
					rows_it.unset ();

			if (applications.size == 0) {
				app_list.add (create_empty_state (_("No background applications")));
			} else if (visible_apps.size == 0) {
				app_list.add (create_empty_state (_("No matching applications")));
			} else {
				foreach (var app in visible_apps) {
					BackgroundAppRow? row = rows[app];
					if (row == null) {
						row = create_row (app);
						rows[app] = row;
					}
					row.update ();
					app_list.add (row);
				}
			}
			app_list.show_all ();

			if (selected_app != null && visible_apps.contains (selected_app))
				app_list.select_row (rows[selected_app]);

			// The panel may have changed its height, so it has to be placed again
			if (visible)
				Idle.add (() => { position_over_item (); return false; });
		}

		Gtk.Widget create_empty_state (string message)
		{
			var row = new Gtk.ListBoxRow () { selectable = false, activatable = false };
			row.get_style_context ().add_class ("background-apps-empty");
			var label = new Gtk.Label (message) { xalign = 0.0f };
			label.margin = 9;
			label.get_style_context ().add_class ("background-apps-empty-label");
			row.add (label);
			Accessibility.describe (row, message);
			return row;
		}

		BackgroundAppRow create_row (TrayStatusItem app)
		{
			var row = new BackgroundAppRow (app);
			row.menu_requested.connect ((button) => {
				int root_x = 0, root_y = 0;
				var window = button.get_window ();
				if (window == null)
					return;
				window.get_origin (out root_x, out root_y);
				Gtk.Allocation allocation;
				button.get_allocation (out allocation);
				app_list.select_row (row);
				show_context_menu_at (app, root_x + allocation.x + allocation.width / 2,
					root_y + allocation.y + allocation.height / 2,
					0U, Gtk.get_current_event_time ());
			});
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

		void move_selection (int delta)
		{
			if (visible_apps.size == 0)
				return;
			var selected = app_list.get_selected_row ();
			var index = selected == null ? 0 : selected.get_index () + delta;
			index = (index + visible_apps.size) % visible_apps.size;
			move_selection_to (index);
		}

		void move_selection_to (int index)
		{
			if (visible_apps.size == 0)
				return;
			index = int.max (0, int.min (visible_apps.size - 1, index));
			var row = app_list.get_row_at_index (index);
			if (row != null) {
				app_list.select_row (row);
				row.grab_focus ();
			}
		}

		void show_selected_context_menu ()
		{
			var row = app_list.get_selected_row ();
			if (row == null || row.get_index () < 0 || row.get_index () >= visible_apps.size)
				return;
			int row_x, row_y;
			if (!row.translate_coordinates (this, 0, 0, out row_x, out row_y))
				return;
			int window_x, window_y;
			get_window ().get_origin (out window_x, out window_y);
			show_context_menu_at (visible_apps[row.get_index ()],
				window_x + row_x + row.get_allocated_width () / 2,
				window_y + row_y + row.get_allocated_height () / 2,
				0U, Gtk.get_current_event_time ());
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
			ContextMenuStyle.prepare (menu, controller);
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

		void position_over_item ()
		{
			if (current_item == null)
				return;
			var item = controller.position_manager.get_screen_region_for_item (current_item);
			var screen = get_screen ();
			var monitor = screen.get_monitor_at_point (item.x, item.y);
			var workarea = screen.get_monitor_workarea (monitor);
			// The height follows the list, so it is asked for rather than known
			int minimum_height, height;
			get_preferred_height (out minimum_height, out height);
			int x, y;
			controller.position_manager.get_popup_position (item, PANEL_WIDTH, height,
				PANEL_GAP, workarea, out x, out y);
			move (x, y);

			growth_x = ((double) (item.x + item.width / 2 - x)).clamp (PANEL_MARGIN,
				PANEL_WIDTH - PANEL_MARGIN);
			growth_y = ((double) (item.y + item.height / 2 - y)).clamp (PANEL_MARGIN,
				double.max (PANEL_MARGIN, height - PANEL_MARGIN));
		}

		void apply_theme ()
		{
			DockStyle.update (controller);
			// The highlight of the selected row is painted, not styled
			if (ContextMenuStyle.is_light (controller.renderer.theme.FillStartColor))
				selection_glide.color = { 24 / 255.0, 27 / 255.0, 32 / 255.0, 0.14 };
			else
				selection_glide.color = { 1.0, 1.0, 1.0, 0.14 };
			selection_glide.animate = Motion.movement_enabled (controller.prefs);
		}
	}

	/**
	 * The row of one application in the background applications panel.
	 */
	class BackgroundAppRow : Gtk.ListBoxRow
	{
		/**
		 * Emitted when the menu of the application is asked for.
		 *
		 * @param button the button which was used to ask for it
		 */
		public signal void menu_requested (Gtk.Widget button);

		public unowned TrayStatusItem app { get; construct; }

		Gtk.Image image;
		Gtk.Label title;
		Gtk.Label detail;
		Gtk.Box dot;
		string shown_icon = "";

		public BackgroundAppRow (TrayStatusItem app)
		{
			Object (app : app);
		}

		construct
		{
			get_style_context ().add_class ("background-app-row");
			var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 10);
			box.margin_left = 8;
			box.margin_right = 6;
			box.margin_top = box.margin_bottom = 7;

			image = new Gtk.Image ();
			image.pixel_size = 28;
			box.pack_start (image, false, false, 0);

			var labels = new Gtk.Box (Gtk.Orientation.VERTICAL, 1);
			labels.valign = Gtk.Align.CENTER;
			title = new Gtk.Label ("") { xalign = 0.0f, ellipsize = Pango.EllipsizeMode.END };
			title.get_style_context ().add_class ("background-app-name");
			labels.pack_start (title, false, false, 0);
			detail = new Gtk.Label ("") { xalign = 0.0f, ellipsize = Pango.EllipsizeMode.END };
			detail.get_style_context ().add_class ("background-app-detail");
			detail.no_show_all = true;
			labels.pack_start (detail, false, false, 0);
			box.pack_start (labels, true, true, 0);

			var more = new Gtk.Button.from_icon_name ("view-more-symbolic", Gtk.IconSize.BUTTON);
			more.relief = Gtk.ReliefStyle.NONE;
			more.valign = Gtk.Align.CENTER;
			more.tooltip_text = _("More options");
			more.get_style_context ().add_class ("background-app-more");
			more.clicked.connect (() => menu_requested (more));
			box.pack_end (more, false, false, 0);

			// Marks an application which wants to be looked at
			dot = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
			dot.valign = Gtk.Align.CENTER;
			dot.get_style_context ().add_class ("background-app-dot");
			dot.no_show_all = true;
			box.pack_end (dot, false, false, 0);

			add (box);
		}

		/**
		 * Shows the application as it currently is.
		 */
		public void update ()
		{
			if (app.Icon != shown_icon) {
				shown_icon = app.Icon;
				if (Path.is_absolute (app.Icon))
					image.set_from_file (app.Icon);
				else
					image.set_from_icon_name (app.Icon, Gtk.IconSize.DIALOG);
				image.pixel_size = 28;
			}

			var attention = (app.Status == "NeedsAttention");
			var text = app.Detail;
			if (text == "" && attention)
				text = _("Needs attention");
			title.label = app.Text;
			detail.label = text;
			detail.visible = (text != "");
			dot.visible = attention;
			if (attention)
				get_style_context ().add_class ("attention");
			else
				get_style_context ().remove_class ("attention");

			Accessibility.describe (this, app.Text, text != "" ? text
				: _("Press Enter to show this application; press Shift+F10 for actions"));
			Accessibility.describe ((Gtk.Widget) dot, _("Needs attention"));
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
