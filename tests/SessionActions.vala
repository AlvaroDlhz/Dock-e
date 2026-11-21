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
}
