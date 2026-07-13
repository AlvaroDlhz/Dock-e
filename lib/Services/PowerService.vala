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
	public enum BatteryState
	{
		UNKNOWN,
		CHARGING,
		DISCHARGING,
		EMPTY,
		FULLY_CHARGED,
		PENDING_CHARGE,
		PENDING_DISCHARGE
	}

	public class PowerSnapshot : Object
	{
		public bool battery_available { get; set; default = false; }
		public double percentage { get; set; default = 0.0; }
		public BatteryState battery_state { get; set; default = BatteryState.UNKNOWN; }
		public int64 time_to_empty { get; set; default = 0; }
		public int64 time_to_full { get; set; default = 0; }
		public double energy_rate { get; set; default = 0.0; }
		public double capacity { get; set; default = 0.0; }
		public int charge_cycles { get; set; default = -1; }
		public bool profiles_available { get; set; default = false; }
		public string active_profile { get; set; default = ""; }
		public Gee.ArrayList<string> profiles { get; private set; }

		public PowerSnapshot ()
		{
			profiles = new Gee.ArrayList<string> ();
		}
	}

	public interface PowerBackend : Object
	{
		public signal void changed ();

		public abstract async PowerSnapshot load (Cancellable? cancellable) throws Error;
		public abstract async void set_profile (string profile,
			Cancellable? cancellable) throws Error;
	}

	public class UPowerBackend : Object, PowerBackend
	{
		const string UPOWER_NAME = "org.freedesktop.UPower";
		const string UPOWER_PATH = "/org/freedesktop/UPower";
		const string UPOWER_IFACE = "org.freedesktop.UPower";
		const string DEVICE_IFACE = "org.freedesktop.UPower.Device";
		const string PROFILES_NAME = "net.hadess.PowerProfiles";
		const string MODERN_PROFILES_PATH = "/org/freedesktop/UPower/PowerProfiles";
		const string MODERN_PROFILES_IFACE = "org.freedesktop.UPower.PowerProfiles";
		const string LEGACY_PROFILES_PATH = "/net/hadess/PowerProfiles";
		const string LEGACY_PROFILES_IFACE = "net.hadess.PowerProfiles";
		const string PROPERTIES_IFACE = "org.freedesktop.DBus.Properties";
		const int DBUS_TIMEOUT_MS = 10000;

		DBusConnection? connection;
		uint upower_subscription_id = 0U;
		uint profiles_subscription_id = 0U;
		string profiles_path = MODERN_PROFILES_PATH;
		string profiles_interface = MODERN_PROFILES_IFACE;

		~UPowerBackend ()
		{
			if (connection == null)
				return;
			if (upower_subscription_id > 0U)
				connection.signal_unsubscribe (upower_subscription_id);
			if (profiles_subscription_id > 0U)
				connection.signal_unsubscribe (profiles_subscription_id);
		}

		public async PowerSnapshot load (Cancellable? cancellable) throws Error
		{
			yield ensure_connection (cancellable);
			var snapshot = new PowerSnapshot ();
			var display_result = yield call (UPOWER_NAME, UPOWER_PATH, UPOWER_IFACE,
				"GetDisplayDevice", null, new VariantType ("(o)"), cancellable);
			var display_path = display_result.get_child_value (0).get_string ();
			if (display_path != "" && display_path != "/") {
				var device = yield get_all (UPOWER_NAME, display_path, DEVICE_IFACE, cancellable);
				snapshot.battery_available = boolean_property (device, "IsPresent")
					&& uint_property (device, "Type") == 2U;
				if (snapshot.battery_available) {
					snapshot.percentage = double_property (device, "Percentage");
					snapshot.battery_state = (BatteryState) uint_property (device, "State");
					snapshot.time_to_empty = int64_property (device, "TimeToEmpty");
					snapshot.time_to_full = int64_property (device, "TimeToFull");
					snapshot.energy_rate = double_property (device, "EnergyRate");
					snapshot.capacity = double_property (device, "Capacity");
					snapshot.charge_cycles = int_property (device, "ChargeCycles", -1);
				}
			}

			try {
				var profile_properties = yield load_profile_properties (cancellable);
				snapshot.active_profile = string_property (profile_properties, "ActiveProfile");
				var profiles_value = profile_properties.lookup_value ("Profiles",
					new VariantType ("aa{sv}"));
				if (profiles_value != null)
					parse_profiles (profiles_value, snapshot.profiles);
				snapshot.profiles_available = snapshot.active_profile != ""
					&& snapshot.profiles.size > 0;
			} catch (Error e) {
				if (cancellable != null && cancellable.is_cancelled ())
					throw e;
			}
			return snapshot;
		}

		public async void set_profile (string profile,
			Cancellable? cancellable) throws Error
		{
			yield ensure_connection (cancellable);
			try {
				yield write_profile (profiles_path, profiles_interface, profile, cancellable);
			} catch (Error e) {
				if (profiles_path == LEGACY_PROFILES_PATH)
					throw e;
				profiles_path = LEGACY_PROFILES_PATH;
				profiles_interface = LEGACY_PROFILES_IFACE;
				yield write_profile (profiles_path, profiles_interface, profile, cancellable);
			}
		}

		async void ensure_connection (Cancellable? cancellable) throws Error
		{
			if (connection != null)
				return;
			connection = yield Bus.get (BusType.SYSTEM, cancellable);
			upower_subscription_id = connection.signal_subscribe (UPOWER_NAME,
				PROPERTIES_IFACE, "PropertiesChanged", null, null, DBusSignalFlags.NONE,
				() => changed ());
			profiles_subscription_id = connection.signal_subscribe (PROFILES_NAME,
				PROPERTIES_IFACE, "PropertiesChanged", null, null, DBusSignalFlags.NONE,
				() => changed ());
		}

		async Variant load_profile_properties (Cancellable? cancellable) throws Error
		{
			try {
				var result = yield get_all (PROFILES_NAME, MODERN_PROFILES_PATH,
					MODERN_PROFILES_IFACE, cancellable);
				profiles_path = MODERN_PROFILES_PATH;
				profiles_interface = MODERN_PROFILES_IFACE;
				return result;
			} catch (Error e) {
				if (cancellable != null && cancellable.is_cancelled ())
					throw e;
				var result = yield get_all (PROFILES_NAME, LEGACY_PROFILES_PATH,
					LEGACY_PROFILES_IFACE, cancellable);
				profiles_path = LEGACY_PROFILES_PATH;
				profiles_interface = LEGACY_PROFILES_IFACE;
				return result;
			}
		}

		async void write_profile (string path, string interface_name, string profile,
			Cancellable? cancellable) throws Error
		{
			yield call (PROFILES_NAME, path, PROPERTIES_IFACE, "Set",
				new Variant ("(ssv)", interface_name, "ActiveProfile",
					new Variant.string (profile)), null, cancellable);
		}

		async Variant get_all (string bus_name, string object_path, string interface_name,
			Cancellable? cancellable) throws Error
		{
			var result = yield call (bus_name, object_path, PROPERTIES_IFACE, "GetAll",
				new Variant ("(s)", interface_name), new VariantType ("(a{sv})"), cancellable);
			return result.get_child_value (0);
		}

		async Variant call (string bus_name, string object_path, string interface_name,
			string method, Variant? parameters, VariantType? reply_type,
			Cancellable? cancellable) throws Error
		{
			yield ensure_connection (cancellable);
			return yield connection.call (bus_name, object_path, interface_name, method,
				parameters, reply_type, DBusCallFlags.NONE, DBUS_TIMEOUT_MS, cancellable);
		}

		public static void parse_profiles (Variant value, Gee.ArrayList<string> result)
		{
			result.clear ();
			for (size_t index = 0; index < value.n_children (); index++) {
				var profile_data = value.get_child_value (index);
				var profile = string_property (profile_data, "Profile");
				if (profile != "" && !result.contains (profile))
					result.add (profile);
			}
			result.sort (compare_profiles);
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

		static int int_property (Variant properties, string name, int fallback)
		{
			var value = properties.lookup_value (name, VariantType.INT32);
			return value != null ? value.get_int32 () : fallback;
		}

		static int64 int64_property (Variant properties, string name)
		{
			var value = properties.lookup_value (name, VariantType.INT64);
			return value != null ? value.get_int64 () : 0;
		}

		static double double_property (Variant properties, string name)
		{
			var value = properties.lookup_value (name, VariantType.DOUBLE);
			return value != null ? value.get_double () : 0.0;
		}

		static string string_property (Variant properties, string name)
		{
			var value = properties.lookup_value (name, VariantType.STRING);
			return value != null ? value.get_string () : "";
		}

		static int compare_profiles (string first, string second)
		{
			return profile_rank (first) - profile_rank (second);
		}

		static int profile_rank (string profile)
		{
			switch (profile) {
			case "power-saver": return 0;
			case "balanced": return 1;
			case "performance": return 2;
			default: return 3;
			}
		}
	}

	public class PowerService : Object
	{
		const uint REFRESH_DEBOUNCE_MS = 100;
		static PowerService? instance;

		public static unowned PowerService get_default ()
		{
			if (instance == null)
				instance = new PowerService.with_backend (new UPowerBackend ());
			return instance;
		}

		public bool battery_available { get; private set; default = false; }
		public double percentage { get; private set; default = 0.0; }
		public BatteryState battery_state { get; private set; default = BatteryState.UNKNOWN; }
		public int64 time_to_empty { get; private set; default = 0; }
		public int64 time_to_full { get; private set; default = 0; }
		public double energy_rate { get; private set; default = 0.0; }
		public double capacity { get; private set; default = 0.0; }
		public int charge_cycles { get; private set; default = -1; }
		public bool profiles_available { get; private set; default = false; }
		public string active_profile { get; private set; default = ""; }
		public bool busy { get; private set; default = false; }
		public string last_error { get; private set; default = ""; }

		public signal void state_changed ();
		public signal void operation_failed (string message);

		PowerBackend backend;
		Cancellable lifetime;
		Gee.ArrayList<string> profiles;
		ulong backend_changed_id = 0UL;
		uint refresh_id = 0U;
		bool refresh_running = false;
		bool refresh_again = false;

		public PowerService.with_backend (PowerBackend backend)
		{
			this.backend = backend;
			lifetime = new Cancellable ();
			profiles = new Gee.ArrayList<string> ();
			backend_changed_id = backend.changed.connect (schedule_refresh);
			refresh.begin ();
		}

		~PowerService ()
		{
			lifetime.cancel ();
			if (backend_changed_id > 0UL && SignalHandler.is_connected (backend, backend_changed_id))
				SignalHandler.disconnect (backend, backend_changed_id);
			if (refresh_id > 0U)
				Source.remove (refresh_id);
		}

		public unowned Gee.ArrayList<string> get_profiles ()
		{
			return profiles;
		}

		public bool is_charging ()
		{
			return battery_state == BatteryState.CHARGING
				|| battery_state == BatteryState.PENDING_CHARGE
				|| battery_state == BatteryState.FULLY_CHARGED;
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

		public async void change_profile (string profile)
		{
			if (busy || !profiles_available || !profiles.contains (profile)
				|| profile == active_profile)
				return;
			busy = true;
			state_changed ();
			try {
				yield backend.set_profile (profile, lifetime);
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

		void apply_snapshot (PowerSnapshot snapshot)
		{
			var did_change = battery_available != snapshot.battery_available
				|| Math.fabs (percentage - snapshot.percentage) > 0.05
				|| battery_state != snapshot.battery_state
				|| time_to_empty != snapshot.time_to_empty || time_to_full != snapshot.time_to_full
				|| Math.fabs (energy_rate - snapshot.energy_rate) > 0.01
				|| Math.fabs (capacity - snapshot.capacity) > 0.05
				|| charge_cycles != snapshot.charge_cycles
				|| profiles_available != snapshot.profiles_available
				|| active_profile != snapshot.active_profile
				|| !profile_lists_equal (profiles, snapshot.profiles);
			battery_available = snapshot.battery_available;
			percentage = snapshot.percentage;
			battery_state = snapshot.battery_state;
			time_to_empty = snapshot.time_to_empty;
			time_to_full = snapshot.time_to_full;
			energy_rate = snapshot.energy_rate;
			capacity = snapshot.capacity;
			charge_cycles = snapshot.charge_cycles;
			profiles_available = snapshot.profiles_available;
			active_profile = snapshot.active_profile;
			profiles.clear ();
			profiles.add_all (snapshot.profiles);
			last_error = "";
			if (did_change)
				state_changed ();
		}

		void apply_unavailable ()
		{
			var did_change = battery_available || profiles_available || profiles.size > 0;
			battery_available = profiles_available = false;
			percentage = energy_rate = capacity = 0.0;
			battery_state = BatteryState.UNKNOWN;
			time_to_empty = time_to_full = 0;
			charge_cycles = -1;
			active_profile = "";
			profiles.clear ();
			if (did_change)
				state_changed ();
		}

		void report_error (Error error)
		{
			if (lifetime.is_cancelled ())
				return;
			last_error = error.message;
			operation_failed (last_error);
		}

		static bool profile_lists_equal (Gee.ArrayList<string> first,
			Gee.ArrayList<string> second)
		{
			if (first.size != second.size)
				return false;
			for (var index = 0; index < first.size; index++)
				if (first[index] != second[index])
					return false;
			return true;
		}
	}
}
