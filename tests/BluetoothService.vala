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

using Plank;

namespace PlankTests
{
	class FakeBluetoothBackend : Object, BluetoothBackend
	{
		public BluetoothSnapshot snapshot = new BluetoothSnapshot ();
		public int power_changes = 0;
		public int discovery_changes = 0;
		public int connection_changes = 0;
		public int removals = 0;
		public bool requested_power = false;

		public async BluetoothSnapshot load (Cancellable? cancellable) throws Error
		{
			return snapshot;
		}

		public async void set_powered (string adapter_path, bool powered,
			Cancellable? cancellable) throws Error
		{
			power_changes++;
			requested_power = powered;
			snapshot.powered = powered;
		}

		public async void set_discovery (string adapter_path, bool discovering,
			Cancellable? cancellable) throws Error
		{
			discovery_changes++;
			snapshot.discovering = discovering;
		}

		public async void set_connected (string device_path, bool connected,
			Cancellable? cancellable) throws Error
		{
			connection_changes++;
		}

		public async void remove_device (string adapter_path, string device_path,
			Cancellable? cancellable) throws Error
		{
			removals++;
		}

		public void notify_changed ()
		{
			changed ();
		}
	}

	delegate bool BluetoothCondition ();

	public static void register_bluetooth_service_tests ()
	{
		Test.add_func ("/Services/BluetoothService/load-snapshot", bluetooth_service_load_snapshot);
		Test.add_func ("/Services/BluetoothService/backend-signal", bluetooth_service_backend_signal);
		Test.add_func ("/Services/BluetoothService/delegate-actions", bluetooth_service_delegate_actions);
		Test.add_func ("/Services/BluetoothService/own-discovery-session", bluetooth_service_own_discovery_session);
		Test.add_func ("/Services/BluetoothService/display-name", bluetooth_service_display_name);
		Test.add_func ("/Services/BluetoothService/parse-managed-objects", bluetooth_service_parse_managed_objects);
	}

	bool wait_for_bluetooth (BluetoothCondition condition, uint timeout_ms = 1000)
	{
		var context = MainContext.default ();
		var deadline = get_monotonic_time () + timeout_ms * 1000;
		while (!condition () && get_monotonic_time () < deadline) {
			while (context.pending ())
				context.iteration (false);
			Thread.usleep (1000);
		}
		return condition ();
	}

	BluetoothSnapshot available_snapshot (bool powered)
	{
		var snapshot = new BluetoothSnapshot () {
			available = true,
			powered = powered,
			adapter_path = "/org/bluez/hci0"
		};
		var device = new BluetoothDevice ("/org/bluez/hci0/dev_00") {
			address = "00:11:22:33:44:55",
			name = "Headphones",
			paired = true,
			connected = true,
			battery_percentage = 72
		};
		snapshot.devices.add (device);
		return snapshot;
	}

	void bluetooth_service_load_snapshot ()
	{
		var backend = new FakeBluetoothBackend ();
		backend.snapshot = available_snapshot (true);
		var service = new BluetoothService.with_backend (backend);
		assert (wait_for_bluetooth (() => service.available && service.get_devices ().size == 1));
		assert (service.powered);
		assert (service.adapter_path == "/org/bluez/hci0");
		assert (service.get_devices ()[0].battery_percentage == 72);
	}

	void bluetooth_service_backend_signal ()
	{
		var backend = new FakeBluetoothBackend ();
		backend.snapshot = available_snapshot (false);
		var service = new BluetoothService.with_backend (backend);
		assert (wait_for_bluetooth (() => service.available));
		backend.snapshot = available_snapshot (true);
		backend.notify_changed ();
		assert (wait_for_bluetooth (() => service.powered));
	}

	void bluetooth_service_delegate_actions ()
	{
		var backend = new FakeBluetoothBackend ();
		backend.snapshot = available_snapshot (false);
		var service = new BluetoothService.with_backend (backend);
		assert (wait_for_bluetooth (() => service.available));
		service.change_powered.begin (true);
		assert (wait_for_bluetooth (() => backend.power_changes == 1 && !service.busy));
		assert (backend.requested_power);
	}

	void bluetooth_service_own_discovery_session ()
	{
		var backend = new FakeBluetoothBackend ();
		backend.snapshot = available_snapshot (true);
		backend.snapshot.discovering = true;
		var service = new BluetoothService.with_backend (backend);
		assert (wait_for_bluetooth (() => service.available && service.discovering));
		service.change_discovery (true);
		assert (wait_for_bluetooth (() => backend.discovery_changes == 1));
		service.change_discovery (false);
		assert (wait_for_bluetooth (() => backend.discovery_changes == 2));
	}

	void bluetooth_service_display_name ()
	{
		assert (BluezBluetoothBackend.display_name ("My Headset", "Fallback", "00:11") == "My Headset");
		assert (BluezBluetoothBackend.display_name ("", "Fallback", "00:11") == "Fallback");
		assert (BluezBluetoothBackend.display_name ("", "", "00:11") == "00:11");
	}

	void bluetooth_service_parse_managed_objects ()
	{
		var adapter_properties = new VariantBuilder (new VariantType ("a{sv}"));
		adapter_properties.add ("{sv}", "Powered", new Variant.boolean (true));
		adapter_properties.add ("{sv}", "Discovering", new Variant.boolean (false));
		var adapter_interfaces = new VariantBuilder (new VariantType ("a{sa{sv}}"));
		adapter_interfaces.add ("{s@a{sv}}", "org.bluez.Adapter1", adapter_properties.end ());

		var device_properties = new VariantBuilder (new VariantType ("a{sv}"));
		device_properties.add ("{sv}", "Address", new Variant.string ("00:11:22:33:44:55"));
		device_properties.add ("{sv}", "Alias", new Variant.string ("Keyboard"));
		device_properties.add ("{sv}", "Connected", new Variant.boolean (true));
		device_properties.add ("{sv}", "Paired", new Variant.boolean (true));
		var battery_properties = new VariantBuilder (new VariantType ("a{sv}"));
		battery_properties.add ("{sv}", "Percentage", new Variant.byte (88));
		var device_interfaces = new VariantBuilder (new VariantType ("a{sa{sv}}"));
		device_interfaces.add ("{s@a{sv}}", "org.bluez.Device1", device_properties.end ());
		device_interfaces.add ("{s@a{sv}}", "org.bluez.Battery1", battery_properties.end ());

		var objects = new VariantBuilder (new VariantType ("a{oa{sa{sv}}}"));
		objects.add ("{o@a{sa{sv}}}", "/org/bluez/hci0", adapter_interfaces.end ());
		objects.add ("{o@a{sa{sv}}}", "/org/bluez/hci0/dev_00", device_interfaces.end ());
		var snapshot = BluezBluetoothBackend.snapshot_from_managed_objects (objects.end ());
		assert (snapshot.available && snapshot.powered && !snapshot.discovering);
		assert (snapshot.adapter_path == "/org/bluez/hci0");
		assert (snapshot.devices.size == 1);
		assert (snapshot.devices[0].name == "Keyboard");
		assert (snapshot.devices[0].battery_percentage == 88);
	}
}
