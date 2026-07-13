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
	class FakeNetworkBackend : Object, NetworkBackend
	{
		public NetworkSnapshot snapshot = new NetworkSnapshot ();
		public int enabled_changes = 0;
		public int scans = 0;
		public int activations = 0;
		public int new_connections = 0;
		public int disconnections = 0;
		public int removals = 0;
		public string received_password = "";

		public async NetworkSnapshot load (Cancellable? cancellable) throws Error
		{
			return snapshot;
		}

		public async void set_enabled (bool enabled, Cancellable? cancellable) throws Error
		{
			enabled_changes++;
			snapshot.enabled = enabled;
		}

		public async void request_scan (string device_path, Cancellable? cancellable) throws Error
		{
			scans++;
		}

		public async void activate (string connection_path, string device_path,
			string access_point_path, Cancellable? cancellable) throws Error
		{
			activations++;
		}

		public async void connect_new (string ssid, string device_path,
			string access_point_path, string? password, Cancellable? cancellable) throws Error
		{
			new_connections++;
			received_password = password ?? "";
		}

		public async void deactivate (string active_connection_path,
			Cancellable? cancellable) throws Error
		{
			disconnections++;
		}

		public async void forget (string connection_path, Cancellable? cancellable) throws Error
		{
			removals++;
		}

		public void notify_changed ()
		{
			changed ();
		}
	}

	delegate bool NetworkCondition ();

	public static void register_network_service_tests ()
	{
		Test.add_func ("/Services/NetworkService/load-snapshot", network_service_load_snapshot);
		Test.add_func ("/Services/NetworkService/backend-signal", network_service_backend_signal);
		Test.add_func ("/Services/NetworkService/delegate-radio-and-scan", network_service_radio_and_scan);
		Test.add_func ("/Services/NetworkService/delegate-network-actions", network_service_network_actions);
		Test.add_func ("/Services/NetworkService/ssid-variant", network_service_ssid_variant);
		Test.add_func ("/Services/NetworkService/connection-settings", network_service_connection_settings);
	}

	bool wait_for_network (NetworkCondition condition, uint timeout_ms = 1000)
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

	NetworkSnapshot wifi_snapshot (bool enabled = true)
	{
		var snapshot = new NetworkSnapshot () {
			available = true,
			enabled = enabled,
			device_path = "/org/freedesktop/NetworkManager/Devices/2",
			active_connection_path = "/org/freedesktop/NetworkManager/ActiveConnection/1",
			ip_address = "192.168.1.10"
		};
		snapshot.networks.add (new WifiNetwork ("Home") {
			strength = 82,
			secure = true,
			connected = true,
			saved = true,
			access_point_path = "/org/freedesktop/NetworkManager/AccessPoint/1",
			connection_path = "/org/freedesktop/NetworkManager/Settings/1"
		});
		return snapshot;
	}

	void network_service_load_snapshot ()
	{
		var backend = new FakeNetworkBackend ();
		backend.snapshot = wifi_snapshot ();
		var service = new Plank.NetworkService.with_backend (backend);
		assert (wait_for_network (() => service.available && service.get_networks ().size == 1));
		assert (service.enabled && service.connected);
		assert (service.ip_address == "192.168.1.10");
		assert (service.get_networks ()[0].ssid == "Home");
	}

	void network_service_backend_signal ()
	{
		var backend = new FakeNetworkBackend ();
		backend.snapshot = wifi_snapshot (false);
		var service = new Plank.NetworkService.with_backend (backend);
		assert (wait_for_network (() => service.available));
		backend.snapshot = wifi_snapshot (true);
		backend.notify_changed ();
		assert (wait_for_network (() => service.enabled && service.connected));
	}

	void network_service_radio_and_scan ()
	{
		var backend = new FakeNetworkBackend ();
		backend.snapshot = wifi_snapshot (true);
		var service = new Plank.NetworkService.with_backend (backend);
		assert (wait_for_network (() => service.available));
		service.change_enabled.begin (false);
		assert (wait_for_network (() => backend.enabled_changes == 1 && !service.busy));
		backend.snapshot.enabled = true;
		backend.notify_changed ();
		assert (wait_for_network (() => service.enabled));
		service.request_scan.begin ();
		assert (wait_for_network (() => backend.scans == 1));
	}

	void network_service_network_actions ()
	{
		var backend = new FakeNetworkBackend ();
		backend.snapshot = wifi_snapshot ();
		var service = new Plank.NetworkService.with_backend (backend);
		assert (wait_for_network (() => service.connected));
		var saved = service.get_networks ()[0];
		service.connect_network.begin (saved);
		assert (wait_for_network (() => backend.activations == 1 && !service.busy));
		service.disconnect_network.begin ();
		assert (wait_for_network (() => backend.disconnections == 1 && !service.busy));
		var nearby = new WifiNetwork ("Cafe") {
			access_point_path = "/org/freedesktop/NetworkManager/AccessPoint/2"
		};
		service.connect_network.begin (nearby, "secret-password");
		assert (wait_for_network (() => backend.new_connections == 1 && !service.busy));
		assert (backend.received_password == "secret-password");
		service.forget_network.begin (saved);
		assert (wait_for_network (() => backend.removals == 1 && !service.busy));
	}

	void network_service_ssid_variant ()
	{
		var value = NetworkManagerBackend.ssid_variant ("Café Wi-Fi");
		assert (value.get_type_string () == "ay");
		assert (NetworkManagerBackend.ssid_from_variant (value) == "Café Wi-Fi");
	}

	void network_service_connection_settings ()
	{
		var settings = NetworkManagerBackend.connection_settings ("Home", "correct horse");
		var connection = settings.lookup_value ("connection", new VariantType ("a{sv}"));
		var wireless = settings.lookup_value ("802-11-wireless", new VariantType ("a{sv}"));
		var security = settings.lookup_value ("802-11-wireless-security", new VariantType ("a{sv}"));
		assert (connection != null && wireless != null && security != null);
		assert (connection.lookup_value ("type", VariantType.STRING).get_string ()
			== "802-11-wireless");
		assert (NetworkManagerBackend.ssid_from_variant (
			wireless.lookup_value ("ssid", new VariantType ("ay"))) == "Home");
		assert (security.lookup_value ("psk", VariantType.STRING).get_string () == "correct horse");
	}
}
