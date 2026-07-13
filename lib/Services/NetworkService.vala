//
//  Copyright (C) 2026 Dock-E contributors
//
//  This file is part of Plank.
//
//  Plank is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//

namespace Plank
{
	public class WifiNetwork : Object
	{
		public string ssid { get; set; default = ""; }
		public int strength { get; set; default = 0; }
		public bool secure { get; set; default = false; }
		public bool connected { get; set; default = false; }
		public bool saved { get; set; default = false; }
		public string access_point_path { get; set; default = ""; }
		public string connection_path { get; set; default = ""; }

		public WifiNetwork (string ssid = "")
		{
			this.ssid = ssid;
		}
	}

	public class NetworkSnapshot : Object
	{
		public bool available { get; set; default = false; }
		public bool enabled { get; set; default = false; }
		public string device_path { get; set; default = ""; }
		public string active_connection_path { get; set; default = ""; }
		public string ip_address { get; set; default = ""; }
		public Gee.ArrayList<WifiNetwork> networks { get; private set; }

		public NetworkSnapshot ()
		{
			networks = new Gee.ArrayList<WifiNetwork> ();
		}
	}

	public interface NetworkBackend : Object
	{
		public signal void changed ();

		public abstract async NetworkSnapshot load (Cancellable? cancellable) throws Error;
		public abstract async void set_enabled (bool enabled, Cancellable? cancellable) throws Error;
		public abstract async void request_scan (string device_path,
			Cancellable? cancellable) throws Error;
		public abstract async void activate (string connection_path, string device_path,
			string access_point_path, Cancellable? cancellable) throws Error;
		public abstract async void connect_new (string ssid, string device_path,
			string access_point_path, string? password, Cancellable? cancellable) throws Error;
		public abstract async void deactivate (string active_connection_path,
			Cancellable? cancellable) throws Error;
		public abstract async void forget (string connection_path,
			Cancellable? cancellable) throws Error;
	}

	public class NetworkManagerBackend : Object, NetworkBackend
	{
		const string NM_NAME = "org.freedesktop.NetworkManager";
		const string NM_PATH = "/org/freedesktop/NetworkManager";
		const string NM_IFACE = "org.freedesktop.NetworkManager";
		const string DEVICE_IFACE = "org.freedesktop.NetworkManager.Device";
		const string WIFI_DEVICE_IFACE = "org.freedesktop.NetworkManager.Device.Wireless";
		const string AP_IFACE = "org.freedesktop.NetworkManager.AccessPoint";
		const string SETTINGS_PATH = "/org/freedesktop/NetworkManager/Settings";
		const string SETTINGS_IFACE = "org.freedesktop.NetworkManager.Settings";
		const string CONNECTION_IFACE = "org.freedesktop.NetworkManager.Settings.Connection";
		const string IP4_IFACE = "org.freedesktop.NetworkManager.IP4Config";
		const string PROPERTIES_IFACE = "org.freedesktop.DBus.Properties";
		const uint WIFI_DEVICE_TYPE = 2U;
		const int DBUS_TIMEOUT_MS = 15000;

		DBusConnection? connection;
		uint properties_subscription_id = 0U;
		uint access_point_added_id = 0U;
		uint access_point_removed_id = 0U;
		uint connection_added_id = 0U;
		uint connection_removed_id = 0U;

		~NetworkManagerBackend ()
		{
			if (connection == null)
				return;
			foreach (var id in new uint[] { properties_subscription_id, access_point_added_id,
				access_point_removed_id, connection_added_id, connection_removed_id })
				if (id > 0U)
					connection.signal_unsubscribe (id);
		}

		public async NetworkSnapshot load (Cancellable? cancellable) throws Error
		{
			yield ensure_connection (cancellable);
			var snapshot = new NetworkSnapshot ();
			var manager = yield get_all (NM_PATH, NM_IFACE, cancellable);
			snapshot.enabled = boolean_property (manager, "WirelessEnabled");

			var device_result = yield call (NM_PATH, NM_IFACE, "GetDevices", null,
				new VariantType ("(ao)"), cancellable);
			var device_paths = device_result.get_child_value (0);
			for (size_t index = 0; index < device_paths.n_children (); index++) {
				var candidate = device_paths.get_child_value (index).get_string ();
				var properties = yield get_all (candidate, DEVICE_IFACE, cancellable);
				if (uint_property (properties, "DeviceType") == WIFI_DEVICE_TYPE) {
					snapshot.available = true;
					snapshot.device_path = candidate;
					break;
				}
			}
			if (!snapshot.available)
				return snapshot;

			var saved_connections = yield load_saved_connections (cancellable);
			var device = yield get_all (snapshot.device_path, DEVICE_IFACE, cancellable);
			snapshot.active_connection_path = object_path_property (device, "ActiveConnection");
			var ip4_path = object_path_property (device, "Ip4Config");
			if (is_object (ip4_path)) {
				var ip4 = yield get_all (ip4_path, IP4_IFACE, cancellable);
				snapshot.ip_address = first_address (ip4);
			}

			var wireless = yield get_all (snapshot.device_path, WIFI_DEVICE_IFACE, cancellable);
			var active_ap = object_path_property (wireless, "ActiveAccessPoint");
			var access_points = wireless.lookup_value ("AccessPoints", new VariantType ("ao"));
			var by_ssid = new Gee.HashMap<string, WifiNetwork> ();
			if (access_points != null)
				for (size_t index = 0; index < access_points.n_children (); index++) {
					var ap_path = access_points.get_child_value (index).get_string ();
					var ap = yield get_all (ap_path, AP_IFACE, cancellable);
					var ssid = ssid_property (ap, "Ssid");
					if (ssid == "")
						continue;
					var strength = (int) byte_property (ap, "Strength");
					var existing = by_ssid.get (ssid);
					if (existing != null && existing.strength >= strength
						&& existing.access_point_path != active_ap)
						continue;
					var network = new WifiNetwork (ssid) {
						strength = strength,
						secure = uint_property (ap, "Flags") != 0U
							|| uint_property (ap, "WpaFlags") != 0U
							|| uint_property (ap, "RsnFlags") != 0U,
						connected = ap_path == active_ap,
						access_point_path = ap_path
					};
					var connection_path = saved_connections.get (ssid);
					if (connection_path != null) {
						network.saved = true;
						network.connection_path = connection_path;
					}
					by_ssid.set (ssid, network);
				}
			foreach (WifiNetwork network in by_ssid.values)
				snapshot.networks.add (network);
			snapshot.networks.sort (compare_networks);
			return snapshot;
		}

		public async void set_enabled (bool enabled, Cancellable? cancellable) throws Error
		{
			yield ensure_connection (cancellable);
			yield connection.call (NM_NAME, NM_PATH, PROPERTIES_IFACE, "Set",
				new Variant ("(ssv)", NM_IFACE, "WirelessEnabled", new Variant.boolean (enabled)),
				null, DBusCallFlags.NONE, DBUS_TIMEOUT_MS, cancellable);
		}

		public async void request_scan (string device_path,
			Cancellable? cancellable) throws Error
		{
			var options = new VariantBuilder (new VariantType ("a{sv}"));
			yield call (device_path, WIFI_DEVICE_IFACE, "RequestScan",
				new Variant ("(@a{sv})", options.end ()), null, cancellable);
		}

		public async void activate (string connection_path, string device_path,
			string access_point_path, Cancellable? cancellable) throws Error
		{
			yield call (NM_PATH, NM_IFACE, "ActivateConnection",
				new Variant ("(ooo)", connection_path, device_path, access_point_path),
				new VariantType ("(o)"), cancellable);
		}

		public async void connect_new (string ssid, string device_path,
			string access_point_path, string? password, Cancellable? cancellable) throws Error
		{
			var settings = connection_settings (ssid, password);
			yield call (NM_PATH, NM_IFACE, "AddAndActivateConnection",
				new Variant ("(@a{sa{sv}}oo)", settings, device_path, access_point_path),
				new VariantType ("(oo)"), cancellable);
		}

		public async void deactivate (string active_connection_path,
			Cancellable? cancellable) throws Error
		{
			yield call (NM_PATH, NM_IFACE, "DeactivateConnection",
				new Variant ("(o)", active_connection_path), null, cancellable);
		}

		public async void forget (string connection_path,
			Cancellable? cancellable) throws Error
		{
			yield call (connection_path, CONNECTION_IFACE, "Delete", null, null, cancellable);
		}

		async void ensure_connection (Cancellable? cancellable) throws Error
		{
			if (connection != null)
				return;
			connection = yield Bus.get (BusType.SYSTEM, cancellable);
			properties_subscription_id = connection.signal_subscribe (NM_NAME,
				PROPERTIES_IFACE, "PropertiesChanged", null, null, DBusSignalFlags.NONE,
				() => changed ());
			access_point_added_id = connection.signal_subscribe (NM_NAME,
				WIFI_DEVICE_IFACE, "AccessPointAdded", null, null, DBusSignalFlags.NONE,
				() => changed ());
			access_point_removed_id = connection.signal_subscribe (NM_NAME,
				WIFI_DEVICE_IFACE, "AccessPointRemoved", null, null, DBusSignalFlags.NONE,
				() => changed ());
			connection_added_id = connection.signal_subscribe (NM_NAME,
				SETTINGS_IFACE, "NewConnection", SETTINGS_PATH, null, DBusSignalFlags.NONE,
				() => changed ());
			connection_removed_id = connection.signal_subscribe (NM_NAME,
				SETTINGS_IFACE, "ConnectionRemoved", SETTINGS_PATH, null, DBusSignalFlags.NONE,
				() => changed ());
		}

		async Gee.HashMap<string, string> load_saved_connections (Cancellable? cancellable)
			throws Error
		{
			var saved = new Gee.HashMap<string, string> ();
			var result = yield call (SETTINGS_PATH, SETTINGS_IFACE, "ListConnections", null,
				new VariantType ("(ao)"), cancellable);
			var paths = result.get_child_value (0);
			for (size_t index = 0; index < paths.n_children (); index++) {
				var path = paths.get_child_value (index).get_string ();
				try {
					var settings_result = yield call (path, CONNECTION_IFACE, "GetSettings", null,
						new VariantType ("(a{sa{sv}})"), cancellable);
					var settings = settings_result.get_child_value (0);
					var wireless = settings.lookup_value ("802-11-wireless",
						new VariantType ("a{sv}"));
					if (wireless == null)
						continue;
					var ssid = ssid_property (wireless, "ssid");
					if (ssid != "" && !saved.has_key (ssid))
						saved.set (ssid, path);
				} catch (Error e) {
					if (cancellable != null && cancellable.is_cancelled ())
						throw e;
				}
			}
			return saved;
		}

		async Variant get_all (string object_path, string interface_name,
			Cancellable? cancellable) throws Error
		{
			var result = yield call (object_path, PROPERTIES_IFACE, "GetAll",
				new Variant ("(s)", interface_name), new VariantType ("(a{sv})"), cancellable);
			return result.get_child_value (0);
		}

		async Variant call (string object_path, string interface_name, string method,
			Variant? parameters, VariantType? reply_type, Cancellable? cancellable) throws Error
		{
			yield ensure_connection (cancellable);
			return yield connection.call (NM_NAME, object_path, interface_name, method,
				parameters, reply_type, DBusCallFlags.NONE, DBUS_TIMEOUT_MS, cancellable);
		}

		public static Variant connection_settings (string ssid, string? password)
		{
			var settings = new VariantBuilder (new VariantType ("a{sa{sv}}"));
			var connection = new VariantBuilder (new VariantType ("a{sv}"));
			connection.add ("{sv}", "id", new Variant.string (ssid));
			connection.add ("{sv}", "type", new Variant.string ("802-11-wireless"));
			settings.add ("{s@a{sv}}", "connection", connection.end ());
			var wireless = new VariantBuilder (new VariantType ("a{sv}"));
			wireless.add ("{sv}", "ssid", ssid_variant (ssid));
			settings.add ("{s@a{sv}}", "802-11-wireless", wireless.end ());
			if (password != null && password != "") {
				var security = new VariantBuilder (new VariantType ("a{sv}"));
				security.add ("{sv}", "key-mgmt", new Variant.string ("wpa-psk"));
				security.add ("{sv}", "psk", new Variant.string (password));
				settings.add ("{s@a{sv}}", "802-11-wireless-security", security.end ());
			}
			return settings.end ();
		}

		public static Variant ssid_variant (string ssid)
		{
			var bytes = new VariantBuilder (new VariantType ("ay"));
			for (var index = 0; index < ssid.length; index++)
				bytes.add ("y", (uchar) ssid[index]);
			return bytes.end ();
		}

		public static string ssid_from_variant (Variant value)
		{
			var result = new StringBuilder ();
			for (size_t index = 0; index < value.n_children (); index++)
				result.append_c ((char) value.get_child_value (index).get_byte ());
			return result.str;
		}

		static string ssid_property (Variant properties, string name)
		{
			var value = properties.lookup_value (name, new VariantType ("ay"));
			return value != null ? ssid_from_variant (value) : "";
		}

		static bool boolean_property (Variant properties, string name)
		{
			var value = properties.lookup_value (name, VariantType.BOOLEAN);
			return value != null && value.get_boolean ();
		}

		static uint uint_property (Variant properties, string name)
		{
			var value = properties.lookup_value (name, VariantType.UINT32);
			return value != null ? value.get_uint32 () : 0U;
		}

		static uchar byte_property (Variant properties, string name)
		{
			var value = properties.lookup_value (name, VariantType.BYTE);
			return value != null ? value.get_byte () : 0;
		}

		static string object_path_property (Variant properties, string name)
		{
			var value = properties.lookup_value (name, VariantType.OBJECT_PATH);
			return value != null ? value.get_string () : "";
		}

		static bool is_object (string path)
		{
			return path != "" && path != "/";
		}

		static string first_address (Variant properties)
		{
			var addresses = properties.lookup_value ("AddressData", new VariantType ("aa{sv}"));
			if (addresses == null || addresses.n_children () == 0)
				return "";
			var first = addresses.get_child_value (0);
			var address = first.lookup_value ("address", VariantType.STRING);
			return address != null ? address.get_string () : "";
		}

		static int compare_networks (WifiNetwork first, WifiNetwork second)
		{
			var first_rank = first.connected ? 0 : (first.saved ? 1 : 2);
			var second_rank = second.connected ? 0 : (second.saved ? 1 : 2);
			if (first_rank != second_rank)
				return first_rank - second_rank;
			if (first.strength != second.strength)
				return second.strength - first.strength;
			return strcmp (first.ssid.down (), second.ssid.down ());
		}
	}

	public class NetworkService : Object
	{
		const uint REFRESH_DEBOUNCE_MS = 100;
		static NetworkService? instance;

		public static unowned NetworkService get_default ()
		{
			if (instance == null)
				instance = new NetworkService.with_backend (new NetworkManagerBackend ());
			return instance;
		}

		public bool available { get; private set; default = false; }
		public bool enabled { get; private set; default = false; }
		public bool connected { get; private set; default = false; }
		public bool busy { get; private set; default = false; }
		public string device_path { get; private set; default = ""; }
		public string active_connection_path { get; private set; default = ""; }
		public string ip_address { get; private set; default = ""; }
		public string last_error { get; private set; default = ""; }

		public signal void state_changed ();
		public signal void networks_changed ();
		public signal void operation_failed (string message);

		NetworkBackend backend;
		Cancellable lifetime;
		Gee.ArrayList<WifiNetwork> networks;
		ulong backend_changed_id = 0UL;
		uint refresh_id = 0U;
		bool refresh_running = false;
		bool refresh_again = false;

		public NetworkService.with_backend (NetworkBackend backend)
		{
			this.backend = backend;
			lifetime = new Cancellable ();
			networks = new Gee.ArrayList<WifiNetwork> ();
			backend_changed_id = backend.changed.connect (schedule_refresh);
			refresh.begin ();
		}

		~NetworkService ()
		{
			lifetime.cancel ();
			if (backend_changed_id > 0UL && SignalHandler.is_connected (backend, backend_changed_id))
				SignalHandler.disconnect (backend, backend_changed_id);
			if (refresh_id > 0U)
				Source.remove (refresh_id);
		}

		public unowned Gee.ArrayList<WifiNetwork> get_networks ()
		{
			return networks;
		}

		public async void refresh ()
		{
			if (refresh_running) {
				refresh_again = true;
				return;
			}
			refresh_running = true;
			do {
				refresh_again = false;
				try {
					apply_snapshot (yield backend.load (lifetime));
				} catch (Error e) {
					if (!lifetime.is_cancelled ())
						apply_unavailable ();
				}
			} while (refresh_again && !lifetime.is_cancelled ());
			refresh_running = false;
		}

		public async void change_enabled (bool value)
		{
			if (!available || busy)
				return;
			busy = true;
			state_changed ();
			try {
				yield backend.set_enabled (value, lifetime);
			} catch (Error e) {
				report_error (e);
			}
			busy = false;
			state_changed ();
			refresh.begin ();
		}

		public async void request_scan ()
		{
			if (!available || !enabled || device_path == "")
				return;
			try {
				yield backend.request_scan (device_path, lifetime);
			} catch (Error e) {
				if (!e.message.contains ("Scanning not allowed"))
					report_error (e);
			}
		}

		public async void connect_network (WifiNetwork network, string? password = null)
		{
			if (busy || device_path == "" || network.access_point_path == "")
				return;
			busy = true;
			state_changed ();
			try {
				if (network.saved && network.connection_path != "")
					yield backend.activate (network.connection_path, device_path,
						network.access_point_path, lifetime);
				else
					yield backend.connect_new (network.ssid, device_path,
						network.access_point_path, password, lifetime);
			} catch (Error e) {
				report_error (e);
			}
			busy = false;
			state_changed ();
			refresh.begin ();
		}

		public async void disconnect_network ()
		{
			if (busy || active_connection_path == "" || active_connection_path == "/")
				return;
			busy = true;
			state_changed ();
			try {
				yield backend.deactivate (active_connection_path, lifetime);
			} catch (Error e) {
				report_error (e);
			}
			busy = false;
			state_changed ();
			refresh.begin ();
		}

		public async void forget_network (WifiNetwork network)
		{
			if (busy || network.connection_path == "")
				return;
			busy = true;
			state_changed ();
			try {
				yield backend.forget (network.connection_path, lifetime);
			} catch (Error e) {
				report_error (e);
			}
			busy = false;
			state_changed ();
			refresh.begin ();
		}

		void schedule_refresh ()
		{
			if (refresh_id > 0U)
				Source.remove (refresh_id);
			refresh_id = Timeout.add (REFRESH_DEBOUNCE_MS, () => {
				refresh_id = 0U;
				refresh.begin ();
				return false;
			});
		}

		void apply_snapshot (NetworkSnapshot snapshot)
		{
			var snapshot_connected = false;
			foreach (WifiNetwork network in snapshot.networks)
				if (network.connected) {
					snapshot_connected = true;
					break;
				}
			var state_did_change = available != snapshot.available || enabled != snapshot.enabled
				|| connected != snapshot_connected || device_path != snapshot.device_path
				|| active_connection_path != snapshot.active_connection_path
				|| ip_address != snapshot.ip_address;
			var networks_did_change = !network_lists_equal (networks, snapshot.networks);
			available = snapshot.available;
			enabled = snapshot.enabled;
			connected = snapshot_connected;
			device_path = snapshot.device_path;
			active_connection_path = snapshot.active_connection_path;
			ip_address = snapshot.ip_address;
			last_error = "";
			if (networks_did_change) {
				networks.clear ();
				networks.add_all (snapshot.networks);
				networks_changed ();
			}
			if (state_did_change)
				state_changed ();
		}

		void apply_unavailable ()
		{
			var state_did_change = available || enabled || connected || device_path != ""
				|| active_connection_path != "" || ip_address != "";
			var had_networks = networks.size > 0;
			available = enabled = connected = false;
			device_path = active_connection_path = ip_address = "";
			networks.clear ();
			if (had_networks)
				networks_changed ();
			if (state_did_change)
				state_changed ();
		}

		void report_error (Error error)
		{
			if (lifetime.is_cancelled ())
				return;
			last_error = error.message;
			operation_failed (last_error);
		}

		static bool network_lists_equal (Gee.ArrayList<WifiNetwork> first,
			Gee.ArrayList<WifiNetwork> second)
		{
			if (first.size != second.size)
				return false;
			for (var index = 0; index < first.size; index++) {
				var left = first[index];
				var right = second[index];
				if (left.ssid != right.ssid || left.strength != right.strength
					|| left.secure != right.secure || left.connected != right.connected
					|| left.saved != right.saved
					|| left.access_point_path != right.access_point_path
					|| left.connection_path != right.connection_path)
					return false;
			}
			return true;
		}
	}
}
