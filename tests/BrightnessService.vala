//
//  Copyright (C) 2026 Dock-E contributors
//
//  This file is part of Plank.
//

using Plank;

namespace PlankTests
{
	class FakeBrightnessBackend : Object, BrightnessBackend
	{
		public BrightnessSnapshot snapshot = new BrightnessSnapshot ();
		public uint delay_ms = 1;
		public int sets = 0;
		public int requested_value = -1;
		public int concurrent = 0;
		public int maximum_concurrent = 0;

		public async BrightnessSnapshot load (Cancellable? cancellable) throws Error
		{
			return snapshot;
		}

		public async void set_value (int value, Cancellable? cancellable) throws Error
		{
			sets++;
			requested_value = value;
			concurrent++;
			maximum_concurrent = int.max (maximum_concurrent, concurrent);
			Timeout.add (delay_ms, set_value.callback);
			yield;
			concurrent--;
			snapshot.value = value;
		}

		public void notify_changed ()
		{
			changed ();
		}
	}

	delegate bool BrightnessCondition ();

	public static void register_brightness_service_tests ()
	{
		Test.add_func ("/Services/BrightnessService/load-state", brightness_service_load_state);
		Test.add_func ("/Services/BrightnessService/backend-signal", brightness_service_backend_signal);
		Test.add_func ("/Services/BrightnessService/set-percentage", brightness_service_set_percentage);
		Test.add_func ("/Services/BrightnessService/coalesce-values", brightness_service_coalesce_values);
		Test.add_func ("/Services/BrightnessService/parse-value", brightness_service_parse_value);
	}

	bool wait_for_brightness (BrightnessCondition condition, uint timeout_ms = 1000)
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

	BrightnessSnapshot available_brightness (int value = 40, int maximum = 100)
	{
		return new BrightnessSnapshot () { available = true, value = value, maximum = maximum };
	}

	void brightness_service_load_state ()
	{
		var backend = new FakeBrightnessBackend () { snapshot = available_brightness () };
		var service = new Plank.BrightnessService.with_backend (backend);
		assert (wait_for_brightness (() => service.available));
		assert (service.value == 40 && service.maximum == 100);
		assert (Math.fabs (service.percentage - 40.0) < 0.01);
	}

	void brightness_service_backend_signal ()
	{
		var backend = new FakeBrightnessBackend () { snapshot = available_brightness () };
		var service = new Plank.BrightnessService.with_backend (backend);
		assert (wait_for_brightness (() => service.available));
		backend.snapshot = available_brightness (65);
		backend.notify_changed ();
		assert (wait_for_brightness (() => service.value == 65));
	}

	void brightness_service_set_percentage ()
	{
		var backend = new FakeBrightnessBackend () { snapshot = available_brightness (20, 200) };
		var service = new Plank.BrightnessService.with_backend (backend);
		assert (wait_for_brightness (() => service.available));
		service.request_percentage (75.0);
		assert (wait_for_brightness (() => backend.sets == 1 && !service.busy));
		assert (backend.requested_value == 150);
		assert (Math.fabs (service.percentage - 75.0) < 0.01);
	}

	void brightness_service_coalesce_values ()
	{
		var backend = new FakeBrightnessBackend () {
			snapshot = available_brightness (), delay_ms = 30
		};
		var service = new Plank.BrightnessService.with_backend (backend);
		assert (wait_for_brightness (() => service.available));
		service.request_percentage (30.0);
		assert (wait_for_brightness (() => backend.concurrent == 1));
		service.request_percentage (70.0);
		service.request_percentage (80.0);
		assert (wait_for_brightness (() => backend.sets == 2 && !service.busy));
		assert (backend.requested_value == 80);
		assert (backend.maximum_concurrent == 1);
	}

	void brightness_service_parse_value ()
	{
		assert (SysfsBrightnessBackend.parse_value ("420\n") == 420);
		assert (SysfsBrightnessBackend.parse_value ("invalid") == -1);
	}
}
