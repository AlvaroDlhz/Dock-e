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
		public abstract async bool check (Cancellable? cancellable) throws Error;
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

		public async bool check (Cancellable? cancellable) throws Error
		{
			if (!supported)
				return false;
			var result = yield runner.run (argv, null, CHECK_TIMEOUT_MS, cancellable);
			if (!result.successful)
				throw new IOError.FAILED ("Update check exited with status %d: %s".printf (
					result.exit_status, result.standard_error.strip ()));
			return output_has_updates (format, result.standard_output);
		}

		public static bool output_has_updates (UpdateCheckFormat format, string output)
		{
			switch (format) {
			case UpdateCheckFormat.MINTUPDATE:
				return output.contains ("package         ") || output.contains ("###");
			case UpdateCheckFormat.APT:
				foreach (unowned string line in output.split ("\n"))
					if (line.contains ("/") && line.contains ("[") && line.contains ("]"))
						return true;
				return false;
			case UpdateCheckFormat.PACKAGEKIT:
				foreach (unowned string line in output.split ("\n"))
					if (line.strip ().has_prefix ("Available")
						|| line.strip ().has_prefix ("Disponible"))
						return true;
				return false;
			default:
				return false;
			}
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
		public bool updates_available { get; private set; default = false; }
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
					var available = yield backend.check (lifetime);
					last_error = "";
					if (updates_available != available) {
						updates_available = available;
						state_changed ();
					}
				} catch (Error e) {
					if (!lifetime.is_cancelled ()) {
						last_error = e.message;
						state_changed ();
					}
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
	}
}
