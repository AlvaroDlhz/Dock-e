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
	public enum UpdateCheckFormat
	{
		MINTUPDATE,
		APT,
		PACKAGEKIT
	}

	public interface UpdateBackend : Object
	{
		public abstract bool supported { get; }
		public abstract async int check (Cancellable? cancellable) throws Error;
	}

	public class CommandUpdateBackend : Object, UpdateBackend
	{
		const uint CHECK_TIMEOUT_MS = 120000;

		public bool supported { get { return argv.length > 0; } }

		CommandRunner runner;
		string[] argv;
		UpdateCheckFormat format;

		public CommandUpdateBackend ()
		{
			runner = new CommandRunner ();
			if (Environment.find_program_in_path ("mintupdate-cli") != null) {
				argv = { "mintupdate-cli", "list" };
				format = UpdateCheckFormat.MINTUPDATE;
			} else if (Environment.find_program_in_path ("apt") != null) {
				argv = { "apt", "list", "--upgradable" };
				format = UpdateCheckFormat.APT;
			} else if (Environment.find_program_in_path ("pkcon") != null) {
				argv = { "pkcon", "get-updates" };
				format = UpdateCheckFormat.PACKAGEKIT;
			} else {
				argv = {};
				format = UpdateCheckFormat.APT;
			}
		}

		public async int check (Cancellable? cancellable) throws Error
		{
			if (!supported)
				return 0;
			var result = yield runner.run (argv, null, CHECK_TIMEOUT_MS, cancellable);
			if (!result.successful)
				throw new IOError.FAILED ("Update check exited with status %d: %s".printf (
					result.exit_status, result.standard_error.strip ()));
			return output_update_count (format, result.standard_output);
		}

		public static int output_update_count (UpdateCheckFormat format, string output)
		{
			var count = 0;
			switch (format) {
			case UpdateCheckFormat.MINTUPDATE:
				// mintupdate-cli prints one non-empty line per available package.
				foreach (unowned string line in output.split ("\n"))
					if (line.strip () != "")
						count++;
				return count;
			case UpdateCheckFormat.APT:
				foreach (unowned string line in output.split ("\n"))
					if (line.contains ("/") && line.contains ("[") && line.contains ("]"))
						count++;
				return count;
			case UpdateCheckFormat.PACKAGEKIT:
				foreach (unowned string line in output.split ("\n"))
					if (line.strip ().has_prefix ("Available")
						|| line.strip ().has_prefix ("Disponible"))
						count++;
				return count;
			default:
				return 0;
			}
		}

		public static bool output_has_updates (UpdateCheckFormat format, string output)
		{
			return output_update_count (format, output) > 0;
		}
	}

	public class UpdateService : Object
	{
		const uint PERIODIC_REFRESH_SECONDS = 300;
		public const uint PACKAGE_CHANGE_DEBOUNCE_SECONDS = 2;
		static UpdateService? instance;

		public static unowned UpdateService get_default ()
		{
			if (instance == null)
				instance = new UpdateService.with_backend (new CommandUpdateBackend (), true);
			return instance;
		}

		public bool supported { get; private set; default = false; }
		public int update_count { get; private set; default = 0; }
		public bool updates_available { get { return update_count > 0; } }
		public bool checking { get; private set; default = false; }
		public string last_error { get; private set; default = ""; }

		public signal void state_changed ();

		UpdateBackend backend;
		Cancellable lifetime;
		FileMonitor? package_monitor;
		uint periodic_refresh_id = 0U;
		uint scheduled_refresh_id = 0U;
		bool refresh_running = false;
		bool refresh_again = false;

		public UpdateService.with_backend (UpdateBackend backend, bool monitor_system = false)
		{
			this.backend = backend;
			lifetime = new Cancellable ();
			supported = backend.supported;
			if (monitor_system)
				start_system_monitoring ();
			Idle.add (() => {
				refresh.begin ();
				return false;
			});
		}

		~UpdateService ()
		{
			lifetime.cancel ();
			if (periodic_refresh_id > 0U)
				Source.remove (periodic_refresh_id);
			if (scheduled_refresh_id > 0U)
				Source.remove (scheduled_refresh_id);
			if (package_monitor != null)
				package_monitor.cancel ();
		}

		public async void refresh ()
		{
			if (!supported || lifetime.is_cancelled ())
				return;
			if (refresh_running) {
				refresh_again = true;
				return;
			}
			refresh_running = true;
			update_checking (true);
			do {
				refresh_again = false;
				try {
					var count = int.max (0, yield backend.check (lifetime));
					update_error ("");
					if (update_count != count) {
						update_count = count;
						state_changed ();
					}
				} catch (Error e) {
					if (!lifetime.is_cancelled ())
						update_error (e.message);
				}
			} while (refresh_again && !lifetime.is_cancelled ());
			refresh_running = false;
			update_checking (false);
		}

		public void schedule_refresh (uint delay_seconds = PACKAGE_CHANGE_DEBOUNCE_SECONDS)
		{
			if (!supported || lifetime.is_cancelled ())
				return;
			if (scheduled_refresh_id > 0U)
				Source.remove (scheduled_refresh_id);
			scheduled_refresh_id = Timeout.add_seconds (delay_seconds, () => {
				scheduled_refresh_id = 0U;
				refresh.begin ();
				return false;
			});
		}

		void start_system_monitoring ()
		{
			periodic_refresh_id = Timeout.add_seconds (PERIODIC_REFRESH_SECONDS, () => {
				refresh.begin ();
				return true;
			});
			try {
				package_monitor = File.new_for_path ("/var/lib/dpkg/status").monitor_file (
					FileMonitorFlags.NONE, lifetime);
				package_monitor.changed.connect (() => schedule_refresh ());
			} catch (Error e) {
				package_monitor = null;
			}
		}

		void update_checking (bool value)
		{
			if (checking == value)
				return;
			checking = value;
			state_changed ();
		}

		void update_error (string value)
		{
			if (last_error == value)
				return;
			last_error = value;
			state_changed ();
		}
	}
}
