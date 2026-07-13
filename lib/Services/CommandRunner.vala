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
	public errordomain CommandError
	{
		INVALID_ARGUMENTS,
		TIMED_OUT
	}

	public class CommandResult : Object
	{
		public int exit_status { get; private set; }
		public string standard_output { get; private set; }
		public string standard_error { get; private set; }
		public bool successful { get { return exit_status == 0; } }

		internal CommandResult (int exit_status, string standard_output, string standard_error)
		{
			this.exit_status = exit_status;
			this.standard_output = standard_output;
			this.standard_error = standard_error;
		}
	}

	public class CommandRunner : Object
	{
		public const uint DEFAULT_TIMEOUT_MS = 10000;

		public async CommandResult run (string[] argv, string? standard_input = null,
			uint timeout_ms = DEFAULT_TIMEOUT_MS, Cancellable? cancellable = null) throws Error
		{
			if (argv.length == 0 || argv[0] == "")
				throw new CommandError.INVALID_ARGUMENTS ("A command executable is required.");
			if (cancellable != null && cancellable.is_cancelled ())
				throw new IOError.CANCELLED ("Command execution was cancelled.");

			var flags = SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_PIPE;
			if (standard_input != null)
				flags |= SubprocessFlags.STDIN_PIPE;
			var process = new Subprocess.newv (argv, flags);
			var operation = new Cancellable ();
			var timed_out = false;
			var caller_cancelled = false;
			uint timeout_id = 0U;
			ulong cancellation_id = 0UL;

			if (cancellable != null) {
				cancellation_id = cancellable.cancelled.connect (() => {
					caller_cancelled = true;
					process.force_exit ();
					operation.cancel ();
				});
			}
			if (timeout_ms > 0U) {
				timeout_id = Timeout.add (timeout_ms, () => {
					timeout_id = 0U;
					timed_out = true;
					process.force_exit ();
					operation.cancel ();
					return false;
				});
			}

			string? standard_output = null;
			string? standard_error = null;
			Error? communication_error = null;
			try {
				yield process.communicate_utf8_async (standard_input, operation,
					out standard_output, out standard_error);
			} catch (Error e) {
				communication_error = e;
			}

			if (timeout_id > 0U)
				Source.remove (timeout_id);
			if (cancellable != null && cancellation_id > 0UL)
				SignalHandler.disconnect (cancellable, cancellation_id);

			if (timed_out)
				throw new CommandError.TIMED_OUT ("Command timed out after %u ms.".printf (timeout_ms));
			if (caller_cancelled)
				throw new IOError.CANCELLED ("Command execution was cancelled.");
			if (communication_error != null)
				throw communication_error;

			var exit_status = process.get_if_exited ()
				? process.get_exit_status ()
				: 128 + process.get_term_sig ();
			return new CommandResult (exit_status, standard_output ?? "", standard_error ?? "");
		}
	}
}
