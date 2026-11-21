//
//  Copyright (C) 2026 Dock-E contributors
//
//  This file is part of Plank.
//

using Plank;

namespace PlankTests
{
	public static void register_session_actions_tests ()
	{
		Test.add_func ("/Services/SessionActions/desktop-session-manager", session_actions_desktop);
		Test.add_func ("/Services/SessionActions/logind-fallback", session_actions_logind);
		Test.add_func ("/Services/SessionActions/unavailable", session_actions_unavailable);
		Test.add_func ("/Services/SessionActions/desktop-names", session_actions_desktop_names);
		Test.add_func ("/Services/SessionActions/hidden", session_actions_hidden);
		Test.add_func ("/Services/TrayWatcher/desktop-first", tray_watcher_desktop_first);
		Test.add_func ("/Services/TrayWatcher/alone", tray_watcher_alone);
		Test.add_func ("/Services/TrayWatcher/replaced", tray_watcher_replaced);
		Test.add_func ("/Services/TrayWatcher/mirrors", tray_watcher_mirrors);
	}

	string? session_command (string action, XdgSessionDesktop desktop, string[] installed,
		string? session_id = null)
	{
		var argv = SessionActions.command_for (action, desktop, session_id,
			(program) => program in installed);
		return argv == null ? null : string.joinv (" ", argv);
	}

	void session_actions_desktop ()
	{
		string[] installed = { "xflock4", "xfce4-session-logout", "cinnamon-session-quit",
			"gnome-session-quit", "systemctl", "loginctl", "gdbus" };
		assert (session_command ("lock", XdgSessionDesktop.XFCE, installed) == "xflock4");
		assert (session_command ("poweroff", XdgSessionDesktop.XFCE, installed) == "xfce4-session-logout --halt");
		assert (session_command ("restart", XdgSessionDesktop.CINNAMON, installed) == "cinnamon-session-quit --reboot");
		assert (session_command ("logout", XdgSessionDesktop.UBUNTU | XdgSessionDesktop.GNOME, installed)
			== "gnome-session-quit --logout --no-prompt");
		assert (session_command ("logout", XdgSessionDesktop.KDE, installed).has_suffix ("org.kde.Shutdown.logout"));
		// The session manager of another desktop is left alone
		assert (session_command ("poweroff", XdgSessionDesktop.MATE, installed) == "systemctl poweroff");
	}

	void session_actions_logind ()
	{
		string[] systemd = { "systemctl", "loginctl" };
		assert (session_command ("lock", XdgSessionDesktop.XFCE, systemd) == "loginctl lock-session");
		assert (session_command ("suspend", XdgSessionDesktop.XFCE, systemd) == "systemctl suspend");
		assert (session_command ("restart", 0, systemd) == "systemctl reboot");
		assert (session_command ("logout", 0, systemd, "c2") == "loginctl terminate-session c2");

		string[] elogind = { "loginctl" };
		assert (session_command ("poweroff", 0, elogind) == "loginctl poweroff");
		assert (session_command ("suspend", 0, elogind) == "loginctl suspend");
	}

	void session_actions_unavailable ()
	{
		string[] nothing = {};
		assert (session_command ("poweroff", XdgSessionDesktop.XFCE, nothing) == null);
		assert (session_command ("logout", 0, { "loginctl" }) == null);
		assert (session_command ("user-settings", XdgSessionDesktop.KDE, { "mugshot" }) == "mugshot");
	}

	void session_actions_desktop_names ()
	{
		assert (XdgSessionDesktop.from_string ("ubuntu:GNOME") == (XdgSessionDesktop.UBUNTU | XdgSessionDesktop.GNOME));
		assert (XdgSessionDesktop.from_string ("X-Cinnamon") == XdgSessionDesktop.CINNAMON);
		assert (XdgSessionDesktop.from_string ("Budgie:GNOME") == (XdgSessionDesktop.BUDGIE | XdgSessionDesktop.GNOME));
		assert (XdgSessionDesktop.from_string ("plasma") == XdgSessionDesktop.KDE);
		assert (XdgSessionDesktop.from_string ("xfce") == XdgSessionDesktop.XFCE);
	}

	void session_actions_hidden ()
	{
		// Shown unless the preference turns them off
		var prefs = new DockPreferences ("session-actions-test");
		assert (prefs.ShowSessionActions);

		string[] session = { "lock", "suspend", "logout", "restart", "poweroff" };
		foreach (unowned string action in session) {
			assert (SessionActions.is_listed (action, true));
			assert (!SessionActions.is_listed (action, false));
		}
		// The preferences of the dock are not a session action
		assert (SessionActions.is_listed ("preferences", false));
		assert (SessionActions.is_listed ("custom:backup", false));
	}

	void tray_watcher_desktop_first ()
	{
		// Plasma or xapp-sn-watcher keeps the list before the dock starts
		var arbiter = new TrayWatcherArbiter ();
		arbiter.name_appeared (false);
		assert (arbiter.role == TrayWatcherRole.HOST);

		// The desktop's watcher restarts: Dock-E waits instead of taking it
		assert (arbiter.name_vanished ());
		assert (arbiter.role == TrayWatcherRole.WAITING);
		arbiter.name_appeared (false);
		assert (!arbiter.claim_due (true));
		assert (arbiter.role == TrayWatcherRole.HOST);
	}

	void tray_watcher_alone ()
	{
		// Nothing keeps the list, so after the delay Dock-E does
		var arbiter = new TrayWatcherArbiter ();
		assert (arbiter.name_vanished ());
		assert (arbiter.claim_due (false));
		assert (arbiter.role == TrayWatcherRole.CLAIMING);
		arbiter.name_appeared (true);
		assert (arbiter.role == TrayWatcherRole.CLAIMING);
		arbiter.name_acquired ();
		assert (arbiter.role == TrayWatcherRole.OWNER);
		// Its own name disappearing never makes it claim twice
		assert (!arbiter.name_vanished ());

		// The desktop took the name just before the delay was over
		var late = new TrayWatcherArbiter ();
		assert (late.name_vanished ());
		assert (!late.claim_due (true));
		assert (late.role == TrayWatcherRole.HOST);
		assert (!late.name_lost ());
	}

	void tray_watcher_replaced ()
	{
		var arbiter = new TrayWatcherArbiter ();
		arbiter.name_vanished ();
		arbiter.claim_due (false);
		arbiter.name_acquired ();

		// The desktop asks for the name, and may announce it before Dock-E hears it lost it
		arbiter.name_appeared (false);
		assert (arbiter.role == TrayWatcherRole.HOST);
		assert (arbiter.name_lost ());
		assert (!arbiter.name_lost ());
		assert (arbiter.role == TrayWatcherRole.HOST);

		// The desktop goes away: Dock-E keeps the list again
		assert (arbiter.name_vanished ());
		assert (arbiter.claim_due (false));

		assert ((TrayWatcherArbiter.OWNER_FLAGS & BusNameOwnerFlags.ALLOW_REPLACEMENT) != 0);
		assert ((TrayWatcherArbiter.OWNER_FLAGS & BusNameOwnerFlags.REPLACE) == 0);
		assert ((TrayWatcherArbiter.OWNER_FLAGS & BusNameOwnerFlags.DO_NOT_QUEUE) != 0);
	}

	void tray_watcher_mirrors ()
	{
		// xapp-sn-watcher (pid 40) shows SNI items as XApp icons of its own
		assert (TrayWatcherArbiter.is_mirrored_icon (40U, 40U));
		// A real XApp icon, like nm-applet
		assert (!TrayWatcherArbiter.is_mirrored_icon (41U, 40U));
		// Dock-E keeps the list, so there is nothing that mirrors
		assert (!TrayWatcherArbiter.is_mirrored_icon (41U, 0U));
		assert (!TrayWatcherArbiter.is_mirrored_icon (0U, 0U));
	}
}
