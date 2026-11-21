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
	/**
	 * Picks the command which locks, suspends or ends the session on the
	 * desktop that is running.
	 *
	 * The session manager of the desktop is preferred, since it saves the
	 * session and lets applications object. Where there is none, or it is
	 * not installed, logind does the job on its own.
	 */
	namespace SessionActions
	{
		/**
		 * Tells whether a program can be run, so that tests can pretend.
		 */
		public delegate bool ProgramFinder (string program);

		const XdgSessionDesktop ANY = 0;
		const XdgSessionDesktop GNOME_LIKE = XdgSessionDesktop.GNOME | XdgSessionDesktop.UNITY
			| XdgSessionDesktop.UBUNTU | XdgSessionDesktop.PANTHEON | XdgSessionDesktop.BUDGIE;

		struct Candidate
		{
			string action;
			XdgSessionDesktop desktops;
			string command;
		}

		// In order of preference. The program is the first word of the command
		const Candidate[] CANDIDATES = {
			{ "lock", XdgSessionDesktop.XFCE, "xflock4" },
			{ "lock", XdgSessionDesktop.CINNAMON, "cinnamon-screensaver-command --lock" },
			{ "lock", XdgSessionDesktop.MATE, "mate-screensaver-command --lock" },
			{ "lock", XdgSessionDesktop.LXQT, "lxqt-leave --lockscreen" },
			{ "lock", ANY, "loginctl lock-session" },
			{ "lock", ANY, "xdg-screensaver lock" },

			{ "suspend", XdgSessionDesktop.XFCE, "xfce4-session-logout --suspend" },
			{ "suspend", XdgSessionDesktop.LXQT, "lxqt-leave --suspend" },
			{ "suspend", ANY, "systemctl suspend" },
			{ "suspend", ANY, "loginctl suspend" },

			{ "logout", XdgSessionDesktop.XFCE, "xfce4-session-logout --logout" },
			{ "logout", XdgSessionDesktop.CINNAMON, "cinnamon-session-quit --logout --no-prompt" },
			{ "logout", XdgSessionDesktop.MATE, "mate-session-save --logout" },
			{ "logout", XdgSessionDesktop.KDE,
				"gdbus call --session --dest org.kde.Shutdown --object-path /Shutdown --method org.kde.Shutdown.logout" },
			{ "logout", XdgSessionDesktop.LXQT, "lxqt-leave --logout" },
			{ "logout", XdgSessionDesktop.LXDE, "lxsession-logout" },
			{ "logout", GNOME_LIKE, "gnome-session-quit --logout --no-prompt" },

			{ "restart", XdgSessionDesktop.XFCE, "xfce4-session-logout --reboot" },
			{ "restart", XdgSessionDesktop.CINNAMON, "cinnamon-session-quit --reboot" },
			{ "restart", XdgSessionDesktop.KDE,
				"gdbus call --session --dest org.kde.Shutdown --object-path /Shutdown --method org.kde.Shutdown.logoutAndReboot" },
			{ "restart", XdgSessionDesktop.LXQT, "lxqt-leave --reboot" },
			{ "restart", GNOME_LIKE, "gnome-session-quit --reboot" },
			{ "restart", ANY, "systemctl reboot" },
			{ "restart", ANY, "loginctl reboot" },

			{ "poweroff", XdgSessionDesktop.XFCE, "xfce4-session-logout --halt" },
			{ "poweroff", XdgSessionDesktop.CINNAMON, "cinnamon-session-quit --power-off" },
			{ "poweroff", XdgSessionDesktop.KDE,
				"gdbus call --session --dest org.kde.Shutdown --object-path /Shutdown --method org.kde.Shutdown.logoutAndShutdown" },
			{ "poweroff", XdgSessionDesktop.LXQT, "lxqt-leave --shutdown" },
			{ "poweroff", GNOME_LIKE, "gnome-session-quit --power-off" },
			{ "poweroff", ANY, "systemctl poweroff" },
			{ "poweroff", ANY, "loginctl poweroff" },

			{ "user-settings", GNOME_LIKE, "gnome-control-center user-accounts" },
			{ "user-settings", XdgSessionDesktop.CINNAMON, "cinnamon-settings user" },
			{ "user-settings", XdgSessionDesktop.MATE, "mate-about-me" },
			{ "user-settings", XdgSessionDesktop.KDE, "systemsettings kcm_users" },
			{ "user-settings", XdgSessionDesktop.KDE, "kcmshell6 kcm_users" },
			{ "user-settings", XdgSessionDesktop.KDE, "kcmshell5 kcm_users" },
			{ "user-settings", ANY, "gnome-control-center user-accounts" },
			{ "user-settings", ANY, "users-admin" },
			{ "user-settings", ANY, "systemsettings kcm_users" },
			{ "user-settings", ANY, "mugshot" },
			{ "user-settings", ANY, "cinnamon-settings user" },
			{ "user-settings", ANY, "mate-about-me" }
		};

		/**
		 * The command for an action on the given desktop.
		 *
		 * @param action one of lock, suspend, logout, restart, poweroff or user-settings
		 * @param desktop the desktops the session claims to be
		 * @param session_id the logind session, to end it where nothing else can
		 * @param has_program tells whether a program is installed
		 * @return the arguments to run, or null if nothing here can do it
		 */
		public static string[]? command_for (string action, XdgSessionDesktop desktop,
			string? session_id, ProgramFinder has_program)
		{
			foreach (unowned Candidate candidate in CANDIDATES) {
				if (candidate.action != action)
					continue;
				if (candidate.desktops != ANY && (candidate.desktops & desktop) == 0)
					continue;
				var argv = candidate.command.split (" ");
				if (has_program (argv[0]))
					return argv;
			}

			// Ends the session at once, without asking the applications
			if (action == "logout" && session_id != null && session_id != "" && has_program ("loginctl"))
				return { "loginctl", "terminate-session", session_id };

			return null;
		}

		/**
		 * The command for an action in the session this process runs in.
		 */
		public static string[]? command_for_session (string action)
		{
			return command_for (action, environment_session_desktop (),
				Environment.get_variable ("XDG_SESSION_ID"),
				(program) => Environment.find_program_in_path (program) != null);
		}
	}
}
