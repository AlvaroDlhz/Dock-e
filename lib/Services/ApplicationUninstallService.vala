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
	public class UninstallTarget : Object
	{
		public string package_id { get; private set; }
		public string source { get; private set; }
		public string[] argv { get; private set; }

		public UninstallTarget (string package_id, string source, string[] argv)
		{
			this.package_id = package_id;
			this.source = source;
			this.argv = argv;
		}
	}

	public interface ApplicationUninstallBackend : Object
	{
		public abstract async string? query (string[] argv, Cancellable? cancellable) throws Error;
	}

	public class CommandApplicationUninstallBackend : Object, ApplicationUninstallBackend
	{
		const uint QUERY_TIMEOUT_MS = 5000;
		CommandRunner runner;

		public CommandApplicationUninstallBackend ()
		{
			runner = new CommandRunner ();
		}

		public async string? query (string[] argv, Cancellable? cancellable) throws Error
		{
			if (argv.length == 0 || Environment.find_program_in_path (argv[0]) == null)
				return null;
			var result = yield runner.run (argv, null, QUERY_TIMEOUT_MS, cancellable);
			return result.successful ? result.standard_output : null;
		}
	}

	public class ApplicationUninstallService : Object
	{
		ApplicationUninstallBackend backend;

		public ApplicationUninstallService ()
		{
			this.with_backend (new CommandApplicationUninstallBackend ());
		}

		public ApplicationUninstallService.with_backend (ApplicationUninstallBackend backend)
		{
			this.backend = backend;
		}

		public async UninstallTarget? detect (string desktop_id, string executable,
			string? desktop_filename, Cancellable? cancellable = null)
		{
			var app_id = desktop_id.has_suffix (".desktop")
				? desktop_id.substring (0, desktop_id.length - 8) : desktop_id;
			if (app_id != "") {
				var output = yield safe_query ({ "flatpak", "info", app_id }, cancellable);
				if (output != null)
					return new UninstallTarget (app_id, "Flatpak",
						{ "flatpak", "uninstall", "--noninteractive", app_id });
				if (cancellable != null && cancellable.is_cancelled ())
					return null;
			}

			var snap_name = snap_package_name (executable);
			if (snap_name != "") {
				var output = yield safe_query ({ "snap", "list", snap_name }, cancellable);
				if (output != null)
					return new UninstallTarget (snap_name, "Snap",
						{ "pkexec", "snap", "remove", snap_name });
				if (cancellable != null && cancellable.is_cancelled ())
					return null;
			}

			if (desktop_filename == null || desktop_filename == "")
				return null;
			var output = yield safe_query ({ "dpkg-query", "-S", desktop_filename }, cancellable);
			var debian_package = parse_dpkg_owner (output ?? "");
			if (debian_package != "")
				return new UninstallTarget (debian_package, "System package",
					{ "pkcon", "remove", "-y", debian_package });
			if (cancellable != null && cancellable.is_cancelled ())
				return null;

			output = yield safe_query ({ "rpm", "-qf", desktop_filename }, cancellable);
			var rpm_package = output != null ? output.strip () : "";
			if (rpm_package != "")
				return new UninstallTarget (rpm_package, "System package",
					{ "pkcon", "remove", "-y", rpm_package });
			return null;
		}

		async string? safe_query (string[] argv, Cancellable? cancellable)
		{
			try {
				return yield backend.query (argv, cancellable);
			} catch (IOError.CANCELLED e) {
				return null;
			} catch (Error e) {
				debug ("Unable to inspect application package with %s: %s", argv[0], e.message);
				return null;
			}
		}

		public static string snap_package_name (string executable)
		{
			var marker = executable.index_of ("/snap/bin/");
			if (marker < 0)
				return "";
			var command = executable.substring (marker + 10).split (" ")[0];
			return command.split (".")[0];
		}

		public static string parse_dpkg_owner (string output)
		{
			if (output == "")
				return "";
			var first_line = output.split ("\n")[0];
			var separator = first_line.index_of (": ");
			return separator > 0 ? first_line.substring (0, separator) : "";
		}
	}
}
