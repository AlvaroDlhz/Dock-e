//
//  Copyright (C) 2026 Dock-E contributors
//
//  This file is part of Plank.
//

using Plank;

namespace PlankTests
{
	public static void register_launcher_search_tests ()
	{
		Test.add_func ("/Services/LauncherSearch/normalize", launcher_search_normalize);
		Test.add_func ("/Services/LauncherSearch/score", launcher_search_score);
		Test.add_func ("/Services/LauncherSearch/highlight", launcher_search_highlight);
		Test.add_func ("/Services/LauncherUsage/score", launcher_usage_score);
		Test.add_func ("/Services/LauncherCatalog/initial", launcher_catalog_initial);
		Test.add_func ("/Services/LauncherCommands/parse", launcher_commands_parse);
		Test.add_func ("/Services/DockProfiles/names", dock_profiles_names);
		Test.add_func ("/Services/DockProfiles/round-trip", dock_profiles_round_trip);
		Test.add_func ("/Services/AccentColor/pick", accent_color_pick);
		Test.add_func ("/Services/AccentColor/wallpaper", accent_color_wallpaper);
	}

	void launcher_commands_parse ()
	{
		var problems = new Gee.ArrayList<string> ();
		var commands = LauncherCommands.parse ("""
[VPN]
Name=Connect to the VPN
Aliases=tunnel;Trabajo;
Icon=network-vpn-symbolic
Exec=nmcli connection up office

[plain]
Exec=true

[two words]
Exec=true

[nothing]
Name=Runs nothing
""", problems);

		assert (commands.size == 2);
		assert (problems.size == 2);

		var vpn = commands[0];
		assert (vpn.id == LauncherCommands.ID_PREFIX + "vpn");
		assert (vpn.name == "Connect to the VPN");
		assert (vpn.icon == "network-vpn-symbolic");
		assert (vpn.argument == "nmcli connection up office");
		assert (vpn.words.length == 3);
		assert (vpn.hint () == "/vpn · /tunnel · /trabajo");
		assert (LauncherSearch.score (vpn.search_text (), "tun") >= 0);

		// What is left out falls back to something usable
		var plain = commands[1];
		assert (plain.name == "plain");
		assert (plain.icon != "");

		assert (LauncherCommands.parse ("this is not a key file", problems).size == 0);
	}

	void dock_profiles_names ()
	{
		assert (DockProfiles.is_valid_name ("trabajo"));
		assert (DockProfiles.is_valid_name ("Presentación 2"));
		assert (DockProfiles.is_valid_name ("modo-oscuro_1"));
		assert (!DockProfiles.is_valid_name (""));
		assert (!DockProfiles.is_valid_name ("../settings"));
		assert (!DockProfiles.is_valid_name ("a/b"));
		assert (!DockProfiles.is_valid_name (".hidden"));
		assert (!DockProfiles.is_valid_name (" padded "));
	}

	void dock_profiles_round_trip ()
	{
		// Kept in memory, so the preferences of a real dock are never touched
		var settings = new GLib.Settings.with_backend_and_path ("net.launchpad.plank.dock.settings",
			SettingsBackend.memory_settings_backend_new (), "/net/launchpad/plank/docks/profile-test/");
		string folder_path;
		try {
			folder_path = DirUtils.make_tmp ("dock-e-profiles-XXXXXX");
		} catch (FileError e) {
			assert_not_reached ();
		}
		var profiles = new DockProfiles (settings, File.new_for_path (folder_path).get_child ("profiles"));
		assert (profiles.list ().length == 0);

		settings.set_int ("icon-size", 64);
		settings.set_string ("theme", "Matte");
		settings.set_boolean ("zoom-enabled", true);
		try {
			profiles.save ("trabajo");
		} catch (Error e) {
			assert_not_reached ();
		}
		assert (profiles.list ().length == 1);
		assert (profiles.list ()[0] == "trabajo");

		settings.set_int ("icon-size", 32);
		settings.set_string ("theme", "Default");
		settings.set_boolean ("zoom-enabled", false);
		try {
			profiles.apply ("trabajo");
		} catch (Error e) {
			assert_not_reached ();
		}
		assert (settings.get_int ("icon-size") == 64);
		assert (settings.get_string ("theme") == "Matte");
		assert (settings.get_boolean ("zoom-enabled") == true);

		// A profile which was never saved changes nothing and says so
		var failed = false;
		try {
			profiles.apply ("ninguno");
		} catch (Error e) {
			failed = true;
		}
		assert (failed);
		assert (settings.get_int ("icon-size") == 64);

		FileUtils.remove (Path.build_filename (folder_path, "profiles", "trabajo.ini"));
		DirUtils.remove (Path.build_filename (folder_path, "profiles"));
		DirUtils.remove (folder_path);
	}

	void accent_color_pick ()
	{
		Gdk.RGBA accent;

		// A grey picture has no color to offer
		var grey = new Gdk.Pixbuf (Gdk.Colorspace.RGB, false, 8, 32, 32);
		grey.fill ((uint32) 0x808080ffU);
		assert (!AccentColor.pick (grey, out accent));

		// The colorful part decides, however much grey surrounds it
		var picture = new Gdk.Pixbuf (Gdk.Colorspace.RGB, false, 8, 32, 32);
		picture.fill ((uint32) 0x303030ffU);
		var blue = new Gdk.Pixbuf (Gdk.Colorspace.RGB, false, 8, 12, 12);
		blue.fill ((uint32) 0x1a4fd0ffU);
		blue.copy_area (0, 0, 12, 12, picture, 4, 4);
		assert (AccentColor.pick (picture, out accent));
		assert (accent.blue > accent.red && accent.blue > accent.green);
		assert (accent.alpha == 1.0);
		// Strong enough to be seen on a dark and on a light bar
		assert (accent.blue > 0.7);
	}

	void accent_color_wallpaper ()
	{
		string first, second;
		try {
			var first_fd = FileUtils.open_tmp ("dock-e-wallpaper-XXXXXX", out first);
			var second_fd = FileUtils.open_tmp ("dock-e-wallpaper-XXXXXX", out second);
			FileUtils.close (first_fd);
			FileUtils.close (second_fd);
		} catch (FileError e) {
			assert_not_reached ();
		}

		var images = new Gee.HashMap<string, string> ();
		images["/backdrop/screen0/monitorGONE-1/workspace0/last-image"] = first;
		images["/backdrop/screen0/monitorHDMI-1/workspace1/last-image"] = first;
		images["/backdrop/screen0/monitorHDMI-1/workspace0/last-image"] = second;
		images["/backdrop/screen0/monitoreDP-1/workspace0/last-image"] = "/nowhere/missing.png";

		// The monitor in use wins over one long gone, its first workspace over the others
		assert (AccentColor.choose_xfce_wallpaper (images, { "HDMI-1" }) == second);
		// A picture which is not there is passed over
		assert (AccentColor.choose_xfce_wallpaper (images, { "eDP-1", "HDMI-1" }) == second);
		// Without a known monitor any picture which exists will do
		assert (AccentColor.choose_xfce_wallpaper (images, {}) != null);
		assert (AccentColor.choose_xfce_wallpaper (new Gee.HashMap<string, string> (), { "HDMI-1" }) == null);

		FileUtils.remove (first);
		FileUtils.remove (second);
	}

	void launcher_catalog_initial ()
	{
		assert (LauncherCatalog.initial_of ("firefox") == "F");
		assert (LauncherCatalog.initial_of ("  Élan") == "E");
		assert (LauncherCatalog.initial_of ("7-Zip") == "#");
		assert (LauncherCatalog.initial_of ("") == "#");
	}

	void launcher_search_normalize ()
	{
		assert (LauncherSearch.normalize ("Configuración") == "configuracion");
		assert (LauncherSearch.normalize ("ÑANDÚ über") == "nandu uber");
		assert (LauncherSearch.initials ("visual studio code") == "vsc");
		assert (LauncherSearch.initials ("gnome-system monitor") == "gsm");
	}

	void launcher_search_score ()
	{
		var name = LauncherSearch.normalize ("Visual Studio Code");
		var prefix = LauncherSearch.score (name, "vis");
		var word = LauncherSearch.score (name, "stu");
		var initials = LauncherSearch.score (name, "vsc");
		var inside = LauncherSearch.score (name, "isua");
		var loose = LauncherSearch.score (name, "vlcd");
		assert (prefix > word && word > initials && initials > inside && inside > loose);
		assert (loose >= 0);
		assert (LauncherSearch.score (name, "xyz") < 0);
		assert (LauncherSearch.score (name, "") == 0);

		assert (LauncherSearch.matches_clearly ("apagar poweroff halt", "apag"));
		assert (LauncherSearch.matches_clearly ("apagar poweroff halt", "power"));
		assert (!LauncherSearch.matches_clearly ("apagar poweroff halt", "gar"));
		assert (!LauncherSearch.matches_clearly ("apagar poweroff halt", ""));
	}

	void launcher_search_highlight ()
	{
		assert (LauncherSearch.highlight ("Thunar", "") == "Thunar");
		assert (LauncherSearch.highlight ("Thunar", "xyz") == "Thunar");
		assert (LauncherSearch.highlight ("A & B", "") == "A &amp; B");
		assert (LauncherSearch.highlight ("Thunar", "thu")
			== "<span weight=\"800\">Thu</span><span alpha=\"62%\">nar</span>");
		assert (LauncherSearch.highlight ("Configuración", "cion")
			== "<span alpha=\"62%\">Configura</span><span weight=\"800\">ción</span>");
		assert (LauncherSearch.highlight ("Zen Browser", "zb")
			== "<span weight=\"800\">Z</span><span alpha=\"62%\">en </span>"
			+ "<span weight=\"800\">B</span><span alpha=\"62%\">rowser</span>");
	}

	void launcher_usage_score ()
	{
		var usage = new LauncherUsage (null);
		int64 day = 86400;
		int64 start = 1000 * day;
		assert (usage.score ("a.desktop", start) == 0.0);

		usage.record ("a.desktop", start);
		usage.record ("a.desktop", start);
		usage.record ("b.desktop", start);
		assert (usage.score ("a.desktop", start) > usage.score ("b.desktop", start));

		// Old habits fade: one launch today outweighs two from months ago
		usage.record ("c.desktop", start + 90 * day);
		assert (usage.score ("c.desktop", start + 90 * day) > usage.score ("a.desktop", start + 90 * day));
		assert (Math.fabs (usage.score ("b.desktop", start + 30 * day) - 0.5) < 0.0001);
	}
}
