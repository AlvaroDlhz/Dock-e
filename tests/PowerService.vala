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
	class FakePowerBackend : Object, PowerBackend
	{
		public PowerSnapshot snapshot = new PowerSnapshot ();
		public int profile_changes = 0;
		public string requested_profile = "";

		public async PowerSnapshot load (Cancellable? cancellable) throws Error
		{
			return snapshot;
		}

		public async void set_profile (string profile, Cancellable? cancellable) throws Error
		{
			profile_changes++;
			requested_profile = profile;
			snapshot.active_profile = profile;
		}

		public void notify_changed ()
		{
			changed ();
		}
	}

	delegate bool PowerCondition ();

	public static void register_power_service_tests ()
	{
		Test.add_func ("/Services/PowerService/load-snapshot", power_service_load_snapshot);
		Test.add_func ("/Services/PowerService/backend-signal", power_service_backend_signal);
		Test.add_func ("/Services/PowerService/change-profile", power_service_change_profile);
		Test.add_func ("/Services/PowerService/reject-profile", power_service_reject_profile);
		Test.add_func ("/Services/PowerService/charging-state", power_service_charging_state);
		Test.add_func ("/Services/PowerService/parse-profiles", power_service_parse_profiles);
	}

	bool wait_for_power (PowerCondition condition, uint timeout_ms = 1000)
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

	PowerSnapshot battery_snapshot (string active_profile = "balanced")
	{
		var snapshot = new PowerSnapshot () {
			battery_available = true,
			percentage = 74.5,
			battery_state = BatteryState.DISCHARGING,
			time_to_empty = 5400,
			energy_rate = 8.4,
			capacity = 91.0,
			charge_cycles = 218,
			profiles_available = true,
			active_profile = active_profile
		};
		snapshot.profiles.add ("power-saver");
		snapshot.profiles.add ("balanced");
		snapshot.profiles.add ("performance");
		return snapshot;
	}

	void power_service_load_snapshot ()
	{
		var backend = new FakePowerBackend ();
		backend.snapshot = battery_snapshot ();
		var service = new Plank.PowerService.with_backend (backend);
		assert (wait_for_power (() => service.battery_available));
		assert (Math.fabs (service.percentage - 74.5) < 0.01);
		assert (service.battery_state == BatteryState.DISCHARGING);
		assert (service.active_profile == "balanced");
		assert (service.get_profiles ().size == 3);
	}

	void power_service_backend_signal ()
	{
		var backend = new FakePowerBackend ();
		backend.snapshot = battery_snapshot ();
		var service = new Plank.PowerService.with_backend (backend);
		assert (wait_for_power (() => service.battery_available));
		backend.snapshot = battery_snapshot ("power-saver");
		backend.notify_changed ();
		assert (wait_for_power (() => service.active_profile == "power-saver"));
	}

	void power_service_change_profile ()
	{
		var backend = new FakePowerBackend ();
		backend.snapshot = battery_snapshot ();
		var service = new Plank.PowerService.with_backend (backend);
		assert (wait_for_power (() => service.profiles_available));
		service.change_profile.begin ("performance");
		assert (wait_for_power (() => backend.profile_changes == 1 && !service.busy));
		assert (backend.requested_profile == "performance");
		assert (wait_for_power (() => service.active_profile == "performance"));
	}

	void power_service_reject_profile ()
	{
		var backend = new FakePowerBackend ();
		backend.snapshot = battery_snapshot ();
		var service = new Plank.PowerService.with_backend (backend);
		assert (wait_for_power (() => service.profiles_available));
		service.change_profile.begin ("balanced");
		service.change_profile.begin ("unsupported");
		assert (!wait_for_power (() => backend.profile_changes > 0, 100));
	}

	void power_service_charging_state ()
	{
		var backend = new FakePowerBackend ();
		backend.snapshot = battery_snapshot ();
		backend.snapshot.battery_state = BatteryState.CHARGING;
		var service = new Plank.PowerService.with_backend (backend);
		assert (wait_for_power (() => service.battery_available));
		assert (service.is_charging ());
		backend.snapshot.battery_state = BatteryState.FULLY_CHARGED;
		backend.notify_changed ();
		assert (wait_for_power (() => service.battery_state == BatteryState.FULLY_CHARGED));
		assert (service.is_charging ());
	}

	void power_service_parse_profiles ()
	{
		var profiles = new VariantBuilder (new VariantType ("aa{sv}"));
		foreach (unowned string id in new string[] { "performance", "power-saver", "balanced" }) {
			var data = new VariantBuilder (new VariantType ("a{sv}"));
			data.add ("{sv}", "Profile", new Variant.string (id));
			profiles.add ("@a{sv}", data.end ());
		}
		var result = new Gee.ArrayList<string> ();
		UPowerBackend.parse_profiles (profiles.end (), result);
		assert (result.size == 3);
		assert (result[0] == "power-saver");
		assert (result[1] == "balanced");
		assert (result[2] == "performance");
	}
}
