//
//  Copyright (C) 2026 Dock-E contributors
//
//  This file is part of Plank.
//

using Plank;

namespace PlankTests
{
	class FakeApplicationUninstallBackend : Object, ApplicationUninstallBackend
	{
		public Gee.HashMap<string, string> answers = new Gee.HashMap<string, string> ();
		public Gee.ArrayList<string> queries = new Gee.ArrayList<string> ();

		public async string? query (string[] argv, Cancellable? cancellable) throws Error
		{
			queries.add (string.joinv ("|", argv));
			Idle.add (query.callback);
			yield;
			if (cancellable != null && cancellable.is_cancelled ())
				throw new IOError.CANCELLED ("cancelled");
			return answers.get (queries.last ());
		}
	}

	public static void register_application_uninstall_service_tests ()
	{
		Test.add_func ("/Services/ApplicationUninstallService/flatpak", uninstall_service_flatpak);
		Test.add_func ("/Services/ApplicationUninstallService/snap", uninstall_service_snap);
		Test.add_func ("/Services/ApplicationUninstallService/dpkg", uninstall_service_dpkg);
		Test.add_func ("/Services/ApplicationUninstallService/rpm", uninstall_service_rpm);
		Test.add_func ("/Services/ApplicationUninstallService/no-owner", uninstall_service_no_owner);
		Test.add_func ("/Services/ApplicationUninstallService/cancellation", uninstall_service_cancellation);
		Test.add_func ("/Services/ApplicationUninstallService/parsers", uninstall_service_parsers);
	}

	UninstallTarget? detect_target (ApplicationUninstallService service, string id,
		string executable, string? filename, Cancellable? cancellable = null)
	{
		var loop = new MainLoop ();
		UninstallTarget? target = null;
		service.detect.begin (id, executable, filename, cancellable, (obj, result) => {
			target = service.detect.end (result);
			loop.quit ();
		});
		loop.run ();
		return target;
	}

	void uninstall_service_flatpak ()
	{
		var backend = new FakeApplicationUninstallBackend ();
		backend.answers["flatpak|info|org.example.App"] = "Example";
		var target = detect_target (new ApplicationUninstallService.with_backend (backend),
			"org.example.App.desktop", "/usr/bin/example", "/apps/example.desktop");
		assert (target != null && target.package_id == "org.example.App" && target.source == "Flatpak");
		assert (string.joinv ("|", target.argv) == "flatpak|uninstall|--noninteractive|org.example.App");
		assert (backend.queries.size == 1);
	}

	void uninstall_service_snap ()
	{
		var backend = new FakeApplicationUninstallBackend ();
		backend.answers["snap|list|code"] = "code 1";
		var target = detect_target (new ApplicationUninstallService.with_backend (backend),
			"code.desktop", "/snap/bin/code --reuse-window", "/apps/code.desktop");
		assert (target != null && target.package_id == "code" && target.source == "Snap");
		assert (string.joinv ("|", target.argv) == "pkexec|snap|remove|code");
	}

	void uninstall_service_dpkg ()
	{
		var backend = new FakeApplicationUninstallBackend ();
		backend.answers["dpkg-query|-S|/usr/share/applications/foo.desktop"] =
			"foo:amd64: /usr/share/applications/foo.desktop\n";
		var target = detect_target (new ApplicationUninstallService.with_backend (backend),
			"foo.desktop", "/usr/bin/foo", "/usr/share/applications/foo.desktop");
		assert (target != null && target.package_id == "foo:amd64");
		assert (string.joinv ("|", target.argv) == "pkcon|remove|-y|foo:amd64");
	}

	void uninstall_service_rpm ()
	{
		var backend = new FakeApplicationUninstallBackend ();
		backend.answers["rpm|-qf|/usr/share/applications/foo.desktop"] = "foo-1.0.x86_64\n";
		var target = detect_target (new ApplicationUninstallService.with_backend (backend),
			"foo.desktop", "/usr/bin/foo", "/usr/share/applications/foo.desktop");
		assert (target != null && target.package_id == "foo-1.0.x86_64");
	}

	void uninstall_service_no_owner ()
	{
		var backend = new FakeApplicationUninstallBackend ();
		var target = detect_target (new ApplicationUninstallService.with_backend (backend),
			"custom.desktop", "/opt/custom", null);
		assert (target == null && backend.queries.size == 1);
	}

	void uninstall_service_cancellation ()
	{
		var backend = new FakeApplicationUninstallBackend ();
		var cancellable = new Cancellable ();
		cancellable.cancel ();
		var target = detect_target (new ApplicationUninstallService.with_backend (backend),
			"custom.desktop", "/usr/bin/custom", "/apps/custom.desktop", cancellable);
		assert (target == null && backend.queries.size == 1);
	}

	void uninstall_service_parsers ()
	{
		assert (ApplicationUninstallService.snap_package_name ("env FOO=1 /snap/bin/firefox.foo --new") == "firefox");
		assert (ApplicationUninstallService.snap_package_name ("/usr/bin/firefox") == "");
		assert (ApplicationUninstallService.parse_dpkg_owner ("libfoo:amd64: /path/file\n") == "libfoo:amd64");
		assert (ApplicationUninstallService.parse_dpkg_owner ("not owned") == "");
	}
}
