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
	public class BrightnessSnapshot : Object
	{
		public bool available { get; set; default = false; }
		public int value { get; set; default = 0; }
		public int maximum { get; set; default = 0; }
	}

	public interface BrightnessBackend : Object
	{
		public signal void changed ();

		public abstract async BrightnessSnapshot load (Cancellable? cancellable) throws Error;
		public abstract async void set_value (int value, Cancellable? cancellable) throws Error;
	}

	public class SysfsBrightnessBackend : Object, BrightnessBackend
	{
		const string BACKLIGHT_PATH = "/sys/class/backlight";
		const string HELPER_PATH = "/usr/sbin/xfpm-power-backlight-helper";
		const uint SET_TIMEOUT_MS = 120000;

		CommandRunner runner;
		File? brightness_file;
		FileMonitor? brightness_monitor;
		ulong monitor_changed_id = 0UL;

		public SysfsBrightnessBackend ()
		{
			runner = new CommandRunner ();
		}

		~SysfsBrightnessBackend ()
		{
			if (brightness_monitor != null && monitor_changed_id > 0UL)
				SignalHandler.disconnect (brightness_monitor, monitor_changed_id);
			if (brightness_monitor != null)
				brightness_monitor.cancel ();
		}

		public async BrightnessSnapshot load (Cancellable? cancellable) throws Error
		{
			var snapshot = new BrightnessSnapshot ();
			var root = File.new_for_path (BACKLIGHT_PATH);
			var enumerator = yield root.enumerate_children_async (FileAttribute.STANDARD_NAME,
				FileQueryInfoFlags.NONE, Priority.DEFAULT, cancellable);
			var entries = yield enumerator.next_files_async (1, Priority.DEFAULT, cancellable);
			yield enumerator.close_async (Priority.DEFAULT, cancellable);
			if (entries == null)
				return snapshot;

			var device = root.get_child (entries.data.get_name ());
			var current_file = device.get_child ("brightness");
			var maximum_file = device.get_child ("max_brightness");
			var current = yield read_int (current_file, cancellable);
			var maximum = yield read_int (maximum_file, cancellable);
			if (current < 0 || maximum <= 0)
				return snapshot;
			configure_monitor (current_file);
			snapshot.available = true;
			snapshot.value = int.min (current, maximum);
			snapshot.maximum = maximum;
			return snapshot;
		}

		public async void set_value (int value, Cancellable? cancellable) throws Error
		{
			var result = yield runner.run ({ "pkexec", HELPER_PATH, "--set-brightness",
				value.to_string () }, null, SET_TIMEOUT_MS, cancellable);
			if (!result.successful)
				throw new IOError.FAILED (result.standard_error.strip () != ""
					? result.standard_error.strip () : "The brightness helper failed.");
		}

		async int read_int (File file, Cancellable? cancellable) throws Error
		{
			uint8[] contents;
			string? etag;
			yield file.load_contents_async (cancellable, out contents, out etag);
			return parse_value ((string) contents);
		}

		void configure_monitor (File file)
		{
			if (brightness_file != null && brightness_file.equal (file))
				return;
			if (brightness_monitor != null && monitor_changed_id > 0UL)
				SignalHandler.disconnect (brightness_monitor, monitor_changed_id);
			if (brightness_monitor != null)
				brightness_monitor.cancel ();
			brightness_file = file;
			try {
				brightness_monitor = file.monitor_file (FileMonitorFlags.NONE);
				monitor_changed_id = brightness_monitor.changed.connect (() => changed ());
			} catch (Error e) {
				brightness_monitor = null;
				monitor_changed_id = 0UL;
			}
		}

		public static int parse_value (string value)
		{
			int result;
			return int.try_parse (value.strip (), out result) ? result : -1;
		}
	}

	public class BrightnessService : Object
	{
		const uint REFRESH_DEBOUNCE_MS = 75;
		static BrightnessService? instance;

		public static unowned BrightnessService get_default ()
		{
			if (instance == null)
				instance = new BrightnessService.with_backend (new SysfsBrightnessBackend ());
			return instance;
		}

		public bool available { get; private set; default = false; }
		public int value { get; private set; default = 0; }
		public int maximum { get; private set; default = 0; }
		public double percentage { get; private set; default = 0.0; }
		public bool busy { get; private set; default = false; }
		public string last_error { get; private set; default = ""; }

		public signal void state_changed ();
		public signal void operation_failed (string message);

		BrightnessBackend backend;
		Cancellable lifetime;
		ulong backend_changed_id = 0UL;
		uint refresh_id = 0U;
		bool refresh_running = false;
		bool refresh_again = false;
		bool apply_running = false;
		double pending_percentage = -1.0;

		public BrightnessService.with_backend (BrightnessBackend backend)
		{
			this.backend = backend;
			lifetime = new Cancellable ();
			backend_changed_id = backend.changed.connect (schedule_refresh);
			refresh.begin ();
		}

		~BrightnessService ()
		{
			lifetime.cancel ();
			if (backend_changed_id > 0UL && SignalHandler.is_connected (backend, backend_changed_id))
				SignalHandler.disconnect (backend, backend_changed_id);
			if (refresh_id > 0U)
				Source.remove (refresh_id);
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
						apply_snapshot (new BrightnessSnapshot ());
				}
			} while (refresh_again && !lifetime.is_cancelled ());
			refresh_running = false;
		}

		public void request_percentage (double requested_percentage)
		{
			if (!available || maximum <= 0)
				return;
			pending_percentage = requested_percentage.clamp (5.0, 100.0);
			if (!apply_running)
				apply_pending.begin ();
		}

		async void apply_pending ()
		{
			apply_running = true;
			busy = true;
			state_changed ();
			while (pending_percentage >= 0.0 && !lifetime.is_cancelled ()) {
				var requested = pending_percentage;
				pending_percentage = -1.0;
				var target = int.max (1, (int) Math.round (maximum * requested / 100.0));
				try {
					yield backend.set_value (target, lifetime);
					value = int.min (target, maximum);
					percentage = 100.0 * value / maximum;
					last_error = "";
					state_changed ();
				} catch (Error e) {
					if (!lifetime.is_cancelled ()) {
						last_error = e.message;
						operation_failed (last_error);
					}
				}
			}
			busy = false;
			apply_running = false;
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

		void apply_snapshot (BrightnessSnapshot snapshot)
		{
			var new_percentage = snapshot.available && snapshot.maximum > 0
				? 100.0 * snapshot.value / snapshot.maximum : 0.0;
			var did_change = available != snapshot.available || value != snapshot.value
				|| maximum != snapshot.maximum || Math.fabs (percentage - new_percentage) > 0.05;
			available = snapshot.available;
			value = snapshot.value;
			maximum = snapshot.maximum;
			percentage = new_percentage;
			if (did_change)
				state_changed ();
		}
	}
}
