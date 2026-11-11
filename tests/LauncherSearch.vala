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
