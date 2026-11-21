//
//  Copyright (C) 2026 Dock-E contributors
//
//  This file is part of Plank.
//

using Plank;

namespace PlankTests
{
	public static void register_launcher_catalog_tests ()
	{
		Test.add_func ("/Services/LauncherCatalog/index-filters", launcher_catalog_index_filters);
		Test.add_func ("/Services/LauncherCatalog/order", launcher_catalog_order);
		Test.add_func ("/Services/LauncherCatalog/search", launcher_catalog_search);
		Test.add_func ("/Services/LauncherCatalog/search-habit", launcher_catalog_search_habit);
		Test.add_func ("/Services/LauncherCatalog/frequent", launcher_catalog_frequent);
		Test.add_func ("/Services/LauncherCatalog/frequent-ties", launcher_catalog_frequent_ties);
		Test.add_func ("/Services/LauncherCatalog/frequent-fading", launcher_catalog_frequent_fading);
	}

	// An application described the way a desktop file would, without any
	// file: its id is its name, which is what the usage history keeps.
	AppInfo catalog_app (string name, string exec = "true", string? comment = null, bool hidden = false)
	{
		var keys = new KeyFile ();
		keys.set_string ("Desktop Entry", "Type", "Application");
		keys.set_string ("Desktop Entry", "Name", name);
		keys.set_string ("Desktop Entry", "Exec", exec);
		if (comment != null)
			keys.set_string ("Desktop Entry", "Comment", comment);
		if (hidden)
			keys.set_boolean ("Desktop Entry", "NoDisplay", true);
		var app = new DesktopAppInfo.from_keyfile (keys);
		assert (app != null);
		return app;
	}

	LauncherCatalog catalog_with (LauncherUsage usage, AppInfo[] apps)
	{
		var installed = new List<AppInfo> ();
		foreach (var app in apps)
			installed.append (app);
		var catalog = new LauncherCatalog (usage);
		catalog.index_applications (installed);
		return catalog;
	}

	string catalog_names (Gee.List<AppInfo> apps)
	{
		string[] names = {};
		foreach (var app in apps)
			names += app.get_display_name ();
		return string.joinv (",", names);
	}

	void launcher_catalog_index_filters ()
	{
		var catalog = catalog_with (new LauncherUsage (null), {
			catalog_app ("Terminal"),
			catalog_app ("Oculta", "true", null, true),
			catalog_app ("Terminal", "sh"),
		});
		// Hidden and repeated ones are left out. GIO itself already refuses
		// desktop files whose program is missing.
		assert (catalog_app ("Firefox").should_show ());
		assert (catalog_names (catalog.applications) == "Terminal");

		// Indexing again starts over
		var installed = new List<AppInfo> ();
		installed.append (catalog_app ("Firefox"));
		catalog.index_applications (installed);
		assert (catalog_names (catalog.applications) == "Firefox");
	}

	void launcher_catalog_order ()
	{
		var catalog = catalog_with (new LauncherUsage (null), {
			catalog_app ("Visual Studio Code"),
			catalog_app ("Élan"),
			catalog_app ("firefox"),
			catalog_app ("7-Zip"),
			catalog_app ("editor"),
			catalog_app ("Terminal"),
		});
		// Names which do not start with a letter come first, accents do not
		// move a name away from its letter, and the case does not matter
		assert (catalog_names (catalog.applications) == "7-Zip,editor,Élan,firefox,Terminal,Visual Studio Code");
	}

	void launcher_catalog_search ()
	{
		var catalog = catalog_with (new LauncherUsage (null), {
			catalog_app ("Visual Studio Code", "true", "Code editing. Redefined."),
			catalog_app ("Editor de texto"),
			catalog_app ("Configuración"),
			catalog_app ("Terminal", "true", "Use the command line"),
		});

		assert (catalog_names (catalog.search ("vsc")) == "Visual Studio Code");
		assert (catalog_names (catalog.search (LauncherSearch.normalize ("configuracion"))) == "Configuración");
		// A match in the name beats one in the description
		assert (catalog_names (catalog.search ("edit")) == "Editor de texto,Visual Studio Code");
		assert (catalog_names (catalog.search ("command")) == "Terminal");
		// A loose match in a description is not worth offering
		assert (catalog.search ("cmdln").size == 0);
		assert (catalog.search ("xyzzy").size == 0);
		// Nothing typed matches everything, in the order of the catalog
		assert (catalog.search ("").size == 4);
	}

	void launcher_catalog_search_habit ()
	{
		var usage = new LauncherUsage (null);
		var catalog = catalog_with (usage, {
			catalog_app ("Terminal"),
			catalog_app ("Termite"),
		});
		// The shorter name matches a little better ...
		assert (catalog_names (catalog.search ("term")) == "Termite,Terminal");
		// ... but the application which is used wins
		usage.record ("Terminal");
		assert (catalog_names (catalog.search ("term")) == "Terminal,Termite");
	}

	void launcher_catalog_frequent ()
	{
		var usage = new LauncherUsage (null);
		var catalog = catalog_with (usage, {
			catalog_app ("Firefox"),
			catalog_app ("Terminal"),
			catalog_app ("Thunar"),
			catalog_app ("Nunca usada"),
		});
		var now = get_real_time () / 1000000;
		for (var i = 0; i < 3; i++)
			usage.record ("Terminal", now);
		usage.record ("Firefox", now);
		usage.record ("Firefox", now);
		usage.record ("Thunar", now);
		// Used, but not in the catalog any more
		usage.record ("Desinstalada", now);
		usage.record ("Desinstalada", now);
		usage.record ("Desinstalada", now);
		usage.record ("Desinstalada", now);

		assert (catalog_names (catalog.frequent (10)) == "Terminal,Firefox,Thunar");
		assert (catalog_names (catalog.frequent (2)) == "Terminal,Firefox");
		assert (catalog.frequent (0).size == 0);
	}

	void launcher_catalog_frequent_ties ()
	{
		var usage = new LauncherUsage (null);
		var catalog = catalog_with (usage, {
			catalog_app ("Zathura"),
			catalog_app ("Gimp"),
			catalog_app ("Atril"),
		});
		var now = get_real_time () / 1000000;
		usage.record ("Zathura", now);
		usage.record ("Gimp", now);
		usage.record ("Atril", now);
		// Equally used applications follow their names
		assert (catalog_names (catalog.frequent (10)) == "Atril,Gimp,Zathura");
	}

	void launcher_catalog_frequent_fading ()
	{
		var usage = new LauncherUsage (null);
		var catalog = catalog_with (usage, {
			catalog_app ("Antigua"),
			catalog_app ("Reciente"),
		});
		var now = get_real_time () / 1000000;
		int64 day = 86400;
		// Many launches a year ago weigh less than one today, yet still count
		for (var i = 0; i < 20; i++)
			usage.record ("Antigua", now - 365 * day);
		usage.record ("Reciente", now);
		assert (catalog_names (catalog.frequent (10)) == "Reciente,Antigua");
	}
}
