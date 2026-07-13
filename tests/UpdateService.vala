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
	class FakeUpdateBackend : Object, UpdateBackend
	{
		public bool is_supported = true;
		public bool supported { get { return is_supported; } }
		public bool answer = false;
		public bool fail = false;
		public uint delay_ms = 1;
		public int checks = 0;
		public int concurrent = 0;
		public int maximum_concurrent = 0;

		public async bool check (Cancellable? cancellable) throws Error
		{
			checks++;
			concurrent++;
			maximum_concurrent = int.max (maximum_concurrent, concurrent);
			Timeout.add (delay_ms, check.callback);
			yield;
			concurrent--;
			if (cancellable != null && cancellable.is_cancelled ())
				throw new IOError.CANCELLED ("cancelled");
			if (fail)
				throw new IOError.FAILED ("check failed");
			return answer;
		}
	}

	delegate bool UpdateCondition ();

	public static void register_update_service_tests ()
	{
		Test.add_func ("/Services/UpdateService/load-state", update_service_load_state);
		Test.add_func ("/Services/UpdateService/refresh-state", update_service_refresh_state);
		Test.add_func ("/Services/UpdateService/coalesce-refreshes", update_service_coalesce_refreshes);
		Test.add_func ("/Services/UpdateService/preserve-cache-on-error", update_service_preserve_cache);
		Test.add_func ("/Services/UpdateService/clear-error-after-recovery", update_service_clear_error);
		Test.add_func ("/Services/UpdateService/parse-apt", update_service_parse_apt);
		Test.add_func ("/Services/UpdateService/parse-backends", update_service_parse_backends);
	}

	bool wait_for_update (UpdateCondition condition, uint timeout_ms = 1000)
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

	void update_service_load_state ()
	{
		var backend = new FakeUpdateBackend () { answer = true };
		var service = new Plank.UpdateService.with_backend (backend);
		assert (wait_for_update (() => backend.checks == 1 && !service.checking));
		assert (service.supported && service.updates_available);
	}

	void update_service_refresh_state ()
	{
		var backend = new FakeUpdateBackend () { answer = false };
		var service = new Plank.UpdateService.with_backend (backend);
		assert (wait_for_update (() => backend.checks == 1 && !service.checking));
		backend.answer = true;
		service.refresh.begin ();
		assert (wait_for_update (() => backend.checks == 2 && !service.checking));
		assert (service.updates_available);
	}

	void update_service_coalesce_refreshes ()
	{
		var backend = new FakeUpdateBackend () { delay_ms = 30 };
		var service = new Plank.UpdateService.with_backend (backend);
		assert (wait_for_update (() => backend.concurrent == 1));
		service.refresh.begin ();
		service.refresh.begin ();
		service.refresh.begin ();
		assert (wait_for_update (() => backend.checks == 2 && !service.checking));
		assert (backend.maximum_concurrent == 1);
		assert (backend.checks == 2);
	}

	void update_service_preserve_cache ()
	{
		var backend = new FakeUpdateBackend () { answer = true };
		var service = new Plank.UpdateService.with_backend (backend);
		assert (wait_for_update (() => service.updates_available && !service.checking));
		backend.fail = true;
		service.refresh.begin ();
		assert (wait_for_update (() => backend.checks == 2 && !service.checking));
		assert (service.updates_available);
		assert (service.last_error == "check failed");
	}

	void update_service_clear_error ()
	{
		var backend = new FakeUpdateBackend () { fail = true };
		var service = new Plank.UpdateService.with_backend (backend);
		assert (wait_for_update (() => backend.checks == 1 && !service.checking));
		assert (service.last_error == "check failed");
		backend.fail = false;
		service.refresh.begin ();
		assert (wait_for_update (() => backend.checks == 2 && !service.checking));
		assert (service.last_error == "");
	}

	void update_service_parse_apt ()
	{
		var with_updates = "Listing...\nlinux/repo 2 amd64 [upgradable from: 1]\n";
		assert (CommandUpdateBackend.output_has_updates (UpdateCheckFormat.APT, with_updates));
		assert (!CommandUpdateBackend.output_has_updates (UpdateCheckFormat.APT, "Listing...\n"));
	}

	void update_service_parse_backends ()
	{
		assert (CommandUpdateBackend.output_has_updates (UpdateCheckFormat.MINTUPDATE,
			"package         old version   new version"));
		assert (CommandUpdateBackend.output_has_updates (UpdateCheckFormat.PACKAGEKIT,
			"Available  firefox;1;x86_64;repo"));
		assert (!CommandUpdateBackend.output_has_updates (UpdateCheckFormat.PACKAGEKIT,
			"No packages require updating"));
	}
}
