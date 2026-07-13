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
	public class BluetoothDevice : Object
	{
		public string object_path { get; set; default = ""; }
		public string address { get; set; default = ""; }
		public string name { get; set; default = ""; }
		public bool connected { get; set; default = false; }
		public bool paired { get; set; default = false; }
		public int battery_percentage { get; set; default = -1; }

		public BluetoothDevice (string object_path = "")
		{
			this.object_path = object_path;
		}
	}

	public class BluetoothSnapshot : Object
	{
		public bool available { get; set; default = false; }
		public bool powered { get; set; default = false; }
		public bool discovering { get; set; default = false; }
		public string adapter_path { get; set; default = ""; }
		public Gee.ArrayList<BluetoothDevice> devices { get; private set; }

		public BluetoothSnapshot ()
		{
			devices = new Gee.ArrayList<BluetoothDevice> ();
		}
	}

	public interface BluetoothBackend : Object
	{
		public signal void changed ();

		public abstract async BluetoothSnapshot load (Cancellable? cancellable) throws Error;
		public abstract async void set_powered (string adapter_path, bool powered,
			Cancellable? cancellable) throws Error;
		public abstract async void set_discovery (string adapter_path, bool discovering,
			Cancellable? cancellable) throws Error;
		public abstract async void set_connected (string device_path, bool connected,
			Cancellable? cancellable) throws Error;
		public abstract async void remove_device (string adapter_path, string device_path,
			Cancellable? cancellable) throws Error;
	}

	public class BluezBluetoothBackend : Object, BluetoothBackend
	{
		const string BLUEZ_NAME = "org.bluez";
		const string OBJECT_MANAGER_IFACE = "org.freedesktop.DBus.ObjectManager";
		const string PROPERTIES_IFACE = "org.freedesktop.DBus.Properties";
		const string ADAPTER_IFACE = "org.bluez.Adapter1";
		const string DEVICE_IFACE = "org.bluez.Device1";
		const string BATTERY_IFACE = "org.bluez.Battery1";
		const int DBUS_TIMEOUT_MS = 10000;

		DBusConnection? connection;
		uint properties_subscription_id = 0U;
		uint added_subscription_id = 0U;
		uint removed_subscription_id = 0U;

		~BluezBluetoothBackend ()
		{
			if (connection == null)
				return;
			if (properties_subscription_id > 0U)
				connection.signal_unsubscribe (properties_subscription_id);
			if (added_subscription_id > 0U)
				connection.signal_unsubscribe (added_subscription_id);
			if (removed_subscription_id > 0U)
				connection.signal_unsubscribe (removed_subscription_id);
		}

		public async BluetoothSnapshot load (Cancellable? cancellable) throws Error
		{
			yield ensure_connection (cancellable);
			var result = yield connection.call (BLUEZ_NAME, "/", OBJECT_MANAGER_IFACE,
				"GetManagedObjects", null, new VariantType ("(a{oa{sa{sv}}})"),
				DBusCallFlags.NONE, DBUS_TIMEOUT_MS, cancellable);
			return snapshot_from_managed_objects (result.get_child_value (0));
		}

		public async void set_powered (string adapter_path, bool powered,
			Cancellable? cancellable) throws Error
		{
			yield write_property (adapter_path, ADAPTER_IFACE, "Powered",
				new Variant.boolean (powered), cancellable);
		}

		public async void set_discovery (string adapter_path, bool discovering,
			Cancellable? cancellable) throws Error
		{
			yield call_method (adapter_path, ADAPTER_IFACE,
				discovering ? "StartDiscovery" : "StopDiscovery", null, cancellable);
		}

		public async void set_connected (string device_path, bool connected,
			Cancellable? cancellable) throws Error
		{
			yield call_method (device_path, DEVICE_IFACE,
				connected ? "Connect" : "Disconnect", null, cancellable);
		}

		public async void remove_device (string adapter_path, string device_path,
			Cancellable? cancellable) throws Error
		{
			yield call_method (adapter_path, ADAPTER_IFACE, "RemoveDevice",
				new Variant ("(o)", device_path), cancellable);
		}

		async void ensure_connection (Cancellable? cancellable) throws Error
		{
			if (connection != null)
				return;
			connection = yield Bus.get (BusType.SYSTEM, cancellable);
			properties_subscription_id = connection.signal_subscribe (BLUEZ_NAME,
				PROPERTIES_IFACE, "PropertiesChanged", null, null, DBusSignalFlags.NONE,
				on_properties_changed);
			added_subscription_id = connection.signal_subscribe (BLUEZ_NAME,
				OBJECT_MANAGER_IFACE, "InterfacesAdded", "/", null, DBusSignalFlags.NONE,
				() => changed ());
			removed_subscription_id = connection.signal_subscribe (BLUEZ_NAME,
				OBJECT_MANAGER_IFACE, "InterfacesRemoved", "/", null, DBusSignalFlags.NONE,
				() => changed ());
		}

		void on_properties_changed (DBusConnection connection, string? sender_name,
			string object_path, string interface_name, string signal_name, Variant parameters)
		{
			var changed_properties = parameters.get_child_value (1);
			string[] relevant = { "Powered", "Discovering", "Connected", "Paired",
				"Alias", "Name", "Address", "Percentage" };
			foreach (unowned string property in relevant) {
				if (changed_properties.lookup_value (property, null) != null) {
					changed ();
					return;
				}
			}
		}

		async void write_property (string object_path, string interface_name,
			string property_name, Variant value, Cancellable? cancellable) throws Error
		{
			yield ensure_connection (cancellable);
			yield connection.call (BLUEZ_NAME, object_path, PROPERTIES_IFACE, "Set",
				new Variant ("(ssv)", interface_name, property_name, value), null,
				DBusCallFlags.NONE, DBUS_TIMEOUT_MS, cancellable);
		}

		async void call_method (string object_path, string interface_name, string method,
			Variant? parameters, Cancellable? cancellable) throws Error
		{
			yield ensure_connection (cancellable);
			yield connection.call (BLUEZ_NAME, object_path, interface_name, method,
				parameters, null, DBusCallFlags.NONE, DBUS_TIMEOUT_MS, cancellable);
		}

		public static BluetoothSnapshot snapshot_from_managed_objects (Variant objects)
		{
			var snapshot = new BluetoothSnapshot ();
			var by_path = new Gee.HashMap<string, BluetoothDevice> ();
			VariantIter object_iterator = objects.iterator ();
			string object_path;
			Variant interfaces;
			while (object_iterator.next ("{o@a{sa{sv}}}", out object_path, out interfaces)) {
				VariantIter interface_iterator = interfaces.iterator ();
				string interface_name;
				Variant properties;
				while (interface_iterator.next ("{s@a{sv}}", out interface_name, out properties)) {
					if (interface_name == ADAPTER_IFACE) {
						var candidate_powered = boolean_property (properties, "Powered");
						if (!snapshot.available || (!snapshot.powered && candidate_powered)) {
							snapshot.available = true;
							snapshot.adapter_path = object_path;
							snapshot.powered = candidate_powered;
							snapshot.discovering = boolean_property (properties, "Discovering");
						}
					} else if (interface_name == DEVICE_IFACE) {
						var device = ensure_device (by_path, object_path);
						device.address = string_property (properties, "Address");
						device.name = display_name (string_property (properties, "Alias"),
							string_property (properties, "Name"), device.address);
						device.connected = boolean_property (properties, "Connected");
						device.paired = boolean_property (properties, "Paired");
					} else if (interface_name == BATTERY_IFACE) {
						var device = ensure_device (by_path, object_path);
						device.battery_percentage = byte_property (properties, "Percentage", -1);
					}
				}
			}
			foreach (BluetoothDevice device in by_path.values) {
				if (device.name != "" && snapshot.adapter_path != ""
					&& device.object_path.has_prefix (snapshot.adapter_path + "/"))
					snapshot.devices.add (device);
			}
			snapshot.devices.sort (compare_devices);
			return snapshot;
		}

		static BluetoothDevice ensure_device (Gee.HashMap<string, BluetoothDevice> devices,
			string object_path)
		{
			var device = devices.get (object_path);
			if (device == null) {
				device = new BluetoothDevice (object_path);
				devices.set (object_path, device);
			}
			return device;
		}

		static bool boolean_property (Variant properties, string name)
		{
			var value = properties.lookup_value (name, VariantType.BOOLEAN);
			return value != null && value.get_boolean ();
		}

		static string string_property (Variant properties, string name)
		{
			var value = properties.lookup_value (name, VariantType.STRING);
			return value != null ? value.get_string () : "";
		}

		static int byte_property (Variant properties, string name, int fallback)
		{
			var value = properties.lookup_value (name, VariantType.BYTE);
			return value != null ? (int) value.get_byte () : fallback;
		}

		public static string display_name (string alias, string name, string address)
		{
			if (alias.strip () != "")
				return alias.strip ();
			if (name.strip () != "")
				return name.strip ();
			return address.strip ();
		}

		static int compare_devices (BluetoothDevice first, BluetoothDevice second)
		{
			var first_rank = first.connected ? 0 : (first.paired ? 1 : 2);
			var second_rank = second.connected ? 0 : (second.paired ? 1 : 2);
			if (first_rank != second_rank)
				return first_rank - second_rank;
			return strcmp (first.name.down (), second.name.down ());
		}
	}

	public class BluetoothService : Object
	{
		const uint REFRESH_DEBOUNCE_MS = 75;
		static BluetoothService? instance;

		public static unowned BluetoothService get_default ()
		{
			if (instance == null)
				instance = new BluetoothService.with_backend (new BluezBluetoothBackend ());
			return instance;
		}

		public bool available { get; private set; default = false; }
		public bool powered { get; private set; default = false; }
		public bool discovering { get; private set; default = false; }
		public bool busy { get; private set; default = false; }
		public string adapter_path { get; private set; default = ""; }
		public string last_error { get; private set; default = ""; }

		public signal void state_changed ();
		public signal void devices_changed ();
		public signal void operation_failed (string message);

		BluetoothBackend backend;
		Cancellable lifetime;
		Gee.ArrayList<BluetoothDevice> devices;
		ulong backend_changed_id = 0UL;
		uint refresh_id = 0U;
		bool refresh_running = false;
		bool refresh_again = false;
		bool discovery_change_running = false;
		bool discovery_dirty = false;
		bool desired_discovery = false;
		bool discovery_session_active = false;

		public BluetoothService.with_backend (BluetoothBackend backend)
		{
			this.backend = backend;
			lifetime = new Cancellable ();
			devices = new Gee.ArrayList<BluetoothDevice> ();
			backend_changed_id = backend.changed.connect (schedule_refresh);
			refresh.begin ();
		}

		~BluetoothService ()
		{
			lifetime.cancel ();
			if (backend_changed_id > 0UL && SignalHandler.is_connected (backend, backend_changed_id))
				SignalHandler.disconnect (backend, backend_changed_id);
			if (refresh_id > 0U)
				Source.remove (refresh_id);
		}

		public unowned Gee.ArrayList<BluetoothDevice> get_devices ()
		{
			return devices;
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
					var snapshot = yield backend.load (lifetime);
					apply_snapshot (snapshot);
				} catch (Error e) {
					if (!lifetime.is_cancelled ())
						apply_unavailable ();
				}
			} while (refresh_again && !lifetime.is_cancelled ());
			refresh_running = false;
		}

		public async void change_powered (bool value)
		{
			if (!available || adapter_path == "" || busy)
				return;
			busy = true;
			state_changed ();
			try {
				yield backend.set_powered (adapter_path, value, lifetime);
				if (!value) {
					desired_discovery = false;
					discovery_session_active = false;
				}
			} catch (Error e) {
				report_error (e);
			}
			busy = false;
			state_changed ();
			refresh.begin ();
		}

		public void change_discovery (bool value)
		{
			desired_discovery = value;
			discovery_dirty = true;
			apply_discovery_change.begin ();
		}

		async void apply_discovery_change ()
		{
			if (discovery_change_running)
				return;
			discovery_change_running = true;
			while (discovery_dirty && !lifetime.is_cancelled ()) {
				discovery_dirty = false;
				if (!available || !powered || adapter_path == ""
					|| discovery_session_active == desired_discovery)
					continue;
				var requested_state = desired_discovery;
				try {
					yield backend.set_discovery (adapter_path, requested_state, lifetime);
					discovery_session_active = requested_state;
				} catch (Error e) {
					if ((requested_state && e.message.contains ("InProgress"))
						|| (!requested_state && e.message.contains ("No discovery started")))
						discovery_session_active = requested_state;
					else if (!e.message.contains ("NotReady"))
						report_error (e);
				}
			}
			discovery_change_running = false;
			refresh.begin ();
		}

		public async void set_connected (BluetoothDevice device, bool value)
		{
			if (busy || device.object_path == "")
				return;
			busy = true;
			state_changed ();
			try {
				yield backend.set_connected (device.object_path, value, lifetime);
			} catch (Error e) {
				report_error (e);
			}
			busy = false;
			state_changed ();
			refresh.begin ();
		}

		public async void remove_device (BluetoothDevice device)
		{
			if (busy || adapter_path == "" || device.object_path == "")
				return;
			busy = true;
			state_changed ();
			try {
				yield backend.remove_device (adapter_path, device.object_path, lifetime);
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

		void apply_snapshot (BluetoothSnapshot snapshot)
		{
			var state_did_change = available != snapshot.available || powered != snapshot.powered
				|| discovering != snapshot.discovering || adapter_path != snapshot.adapter_path;
			var devices_did_change = !device_lists_equal (devices, snapshot.devices);
			available = snapshot.available;
			powered = snapshot.powered;
			discovering = snapshot.discovering;
			adapter_path = snapshot.adapter_path;
			last_error = "";
			if (devices_did_change) {
				devices.clear ();
				devices.add_all (snapshot.devices);
				devices_changed ();
			}
			if (state_did_change)
				state_changed ();
		}

		void apply_unavailable ()
		{
			var state_did_change = available || powered || discovering || adapter_path != "";
			var had_devices = devices.size > 0;
			available = powered = discovering = false;
			adapter_path = "";
			devices.clear ();
			if (had_devices)
				devices_changed ();
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

		static bool device_lists_equal (Gee.ArrayList<BluetoothDevice> first,
			Gee.ArrayList<BluetoothDevice> second)
		{
			if (first.size != second.size)
				return false;
			for (var index = 0; index < first.size; index++) {
				var left = first[index];
				var right = second[index];
				if (left.object_path != right.object_path || left.address != right.address
					|| left.name != right.name || left.connected != right.connected
					|| left.paired != right.paired
					|| left.battery_percentage != right.battery_percentage)
					return false;
			}
			return true;
		}
	}
}
