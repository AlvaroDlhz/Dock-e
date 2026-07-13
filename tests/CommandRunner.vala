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
	public static void register_command_runner_tests ()
	{
		Test.add_func ("/Services/CommandRunner/output", command_runner_output);
		Test.add_func ("/Services/CommandRunner/exit-status", command_runner_exit_status);
		Test.add_func ("/Services/CommandRunner/spawn-error", command_runner_spawn_error);
		Test.add_func ("/Services/CommandRunner/timeout", command_runner_timeout);
		Test.add_func ("/Services/CommandRunner/cancellation", command_runner_cancellation);
		Test.add_func ("/Services/CommandRunner/invalid-arguments", command_runner_invalid_arguments);
	}

	CommandResult? run_command (string[] argv, uint timeout_ms, Cancellable? cancellable, out Error? error)
	{
		var loop = new MainLoop ();
		var runner = new CommandRunner ();
		CommandResult? result = null;
		Error? command_error = null;
		runner.run.begin (argv, null, timeout_ms, cancellable, (obj, res) => {
			try {
				result = runner.run.end (res);
			} catch (Error e) {
				command_error = e;
			}
			loop.quit ();
		});
		loop.run ();
		error = command_error;
		return result;
	}

	void command_runner_output ()
	{
		Error? error;
		var result = run_command ({ "/bin/sh", "-c", "printf output; printf error >&2" },
			1000, null, out error);
		assert (error == null);
		assert (result != null);
		assert (result.successful);
		assert (result.standard_output == "output");
		assert (result.standard_error == "error");
	}

	void command_runner_exit_status ()
	{
		Error? error;
		var result = run_command ({ "/bin/false" }, 1000, null, out error);
		assert (error == null);
		assert (result != null);
		assert (!result.successful);
		assert (result.exit_status != 0);
	}

	void command_runner_spawn_error ()
	{
		Error? error;
		var result = run_command ({ "/dock-e-command-that-does-not-exist" }, 1000, null, out error);
		assert (result == null);
		assert (error != null);
	}

	void command_runner_timeout ()
	{
		Error? error;
		var result = run_command ({ "/bin/sleep", "2" }, 30, null, out error);
		assert (result == null);
		assert (error != null && error.code == (int) CommandError.TIMED_OUT);
	}

	void command_runner_cancellation ()
	{
		var cancellable = new Cancellable ();
		Timeout.add (30, () => { cancellable.cancel (); return false; });
		Error? error;
		var result = run_command ({ "/bin/sleep", "2" }, 1000, cancellable, out error);
		assert (result == null);
		assert (error != null && error.matches (IOError.quark (), IOError.CANCELLED));
	}

	void command_runner_invalid_arguments ()
	{
		Error? error;
		var result = run_command ({}, 1000, null, out error);
		assert (result == null);
		assert (error != null && error.code == (int) CommandError.INVALID_ARGUMENTS);
	}
}
