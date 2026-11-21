//
//  Copyright (C) 2026 Dock-E contributors
//
//  This file is part of Plank.
//

using Plank;

namespace PlankTests
{
	public static void register_dock_profiles_tests ()
	{
		Test.add_func ("/Services/DockProfiles/list-sorted", dock_profiles_list_sorted);
		Test.add_func ("/Services/DockProfiles/save-replaces", dock_profiles_save_replaces);
		Test.add_func ("/Services/DockProfiles/list-ignores-foreign-files", dock_profiles_list_ignores_foreign_files);
		Test.add_func ("/Services/DockProfiles/invalid-names", dock_profiles_invalid_names);
		Test.add_func ("/Services/DockProfiles/rejects-invalid-names", dock_profiles_rejects_invalid_names);
		Test.add_func ("/Services/DockProfiles/apply-tolerates-damage", dock_profiles_apply_tolerates_damage);
		Test.add_func ("/Services/DockProfiles/apply-delayed", dock_profiles_apply_delayed);
	}

	// Preferences kept in memory, so the ones of a real dock are never touched
	GLib.Settings profile_test_settings ()
	{
		return new GLib.Settings.with_backend_and_path ("net.launchpad.plank.dock.settings",
			SettingsBackend.memory_settings_backend_new (), "/net/launchpad/plank/docks/profile-test/");
	}

	string profile_test_folder ()
	{
		try {
			return DirUtils.make_tmp ("dock-e-profiles-XXXXXX");
		} catch (FileError e) {
			assert_not_reached ();
		}
	}

	void remove_profile_test_folder (string path)
	{
		try {
			var directory = Dir.open (path);
			unowned string? entry;
			while ((entry = directory.read_name ()) != null) {
				var child = Path.build_filename (path, entry);
				if (FileUtils.test (child, FileTest.IS_DIR))
					remove_profile_test_folder (child);
				else
					FileUtils.remove (child);
			}
		} catch (FileError e) {
			// Nothing was left behind
		}
		DirUtils.remove (path);
	}

	void save_profile (DockProfiles profiles, string name)
	{
		try {
			profiles.save (name);
		} catch (Error e) {
			assert_not_reached ();
		}
	}

	void apply_profile (DockProfiles profiles, string name)
	{
		try {
			profiles.apply (name);
		} catch (Error e) {
			assert_not_reached ();
		}
	}

	void dock_profiles_list_sorted ()
	{
		var settings = profile_test_settings ();
		var root = profile_test_folder ();
		// The folder does not exist until the first profile is saved
		var profiles = new DockProfiles (settings, File.new_for_path (root).get_child ("profiles"));
		assert (profiles.list ().length == 0);

		save_profile (profiles, "zeta");
		save_profile (profiles, "alfa");
		save_profile (profiles, "media pantalla");

		var names = profiles.list ();
		assert (names.length == 3);
		assert (names[0] == "alfa");
		assert (names[1] == "media pantalla");
		assert (names[2] == "zeta");

		// Another instance over the same folder finds the same profiles
		var again = new DockProfiles (settings, File.new_for_path (root).get_child ("profiles"));
		assert (string.joinv (",", again.list ()) == "alfa,media pantalla,zeta");

		remove_profile_test_folder (root);
	}

	void dock_profiles_save_replaces ()
	{
		var settings = profile_test_settings ();
		var root = profile_test_folder ();
		var profiles = new DockProfiles (settings, File.new_for_path (root));

		settings.set_int ("icon-size", 64);
		save_profile (profiles, "trabajo");
		settings.set_int ("icon-size", 40);
		settings.set_strv ("dock-items", { "firefox.dockitem", "thunar.dockitem" });
		save_profile (profiles, "trabajo");
		assert (profiles.list ().length == 1);

		settings.set_int ("icon-size", 32);
		settings.set_strv ("dock-items", {});
		apply_profile (profiles, "trabajo");
		// The last save wins, and lists come back as they were
		assert (settings.get_int ("icon-size") == 40);
		assert (string.joinv (",", settings.get_strv ("dock-items")) == "firefox.dockitem,thunar.dockitem");

		remove_profile_test_folder (root);
	}

	void dock_profiles_list_ignores_foreign_files ()
	{
		var settings = profile_test_settings ();
		var root = profile_test_folder ();
		var profiles = new DockProfiles (settings, File.new_for_path (root));

		try {
			FileUtils.set_contents (Path.build_filename (root, "notas.txt"), "");
			FileUtils.set_contents (Path.build_filename (root, ".oculto.ini"), "");
			FileUtils.set_contents (Path.build_filename (root, "con punto.v2.ini"), "");
			FileUtils.set_contents (Path.build_filename (root, "casa.ini"), "[Dock]\n");
		} catch (FileError e) {
			assert_not_reached ();
		}
		DirUtils.create (Path.build_filename (root, "carpeta"), 0700);

		var names = profiles.list ();
		assert (names.length == 1);
		assert (names[0] == "casa");

		remove_profile_test_folder (root);
	}

	void dock_profiles_invalid_names ()
	{
		assert (DockProfiles.is_valid_name ("Ñandú"));
		assert (DockProfiles.is_valid_name (string.nfill (40, 'a')));
		assert (!DockProfiles.is_valid_name (string.nfill (41, 'a')));
		assert (!DockProfiles.is_valid_name ("con.punto"));
		assert (!DockProfiles.is_valid_name ("a\\b"));
		assert (!DockProfiles.is_valid_name ("tab\there"));
		assert (!DockProfiles.is_valid_name ("salto\n"));
		assert (!DockProfiles.is_valid_name ("~"));
		assert (!DockProfiles.is_valid_name (".."));
		assert (!DockProfiles.is_valid_name ("final "));
		assert (!DockProfiles.is_valid_name (" inicio"));
	}

	void dock_profiles_rejects_invalid_names ()
	{
		var settings = profile_test_settings ();
		var root = profile_test_folder ();
		var profiles = new DockProfiles (settings, File.new_for_path (root).get_child ("profiles"));

		foreach (var name in new string[] { "", "../escape", "a/b", ".hidden", " padded" }) {
			var refused = false;
			try {
				profiles.save (name);
			} catch (IOError.INVALID_FILENAME e) {
				refused = true;
			} catch (Error e) {
				assert_not_reached ();
			}
			assert (refused);

			refused = false;
			try {
				profiles.apply (name);
			} catch (IOError.INVALID_FILENAME e) {
				refused = true;
			} catch (Error e) {
				assert_not_reached ();
			}
			assert (refused);
		}

		// Nothing was written, not even the folder, and nothing escaped it
		assert (!FileUtils.test (Path.build_filename (root, "profiles"), FileTest.EXISTS));
		assert (!FileUtils.test (Path.build_filename (root, "escape.ini"), FileTest.EXISTS));
		assert (profiles.list ().length == 0);

		remove_profile_test_folder (root);
	}

	void dock_profiles_apply_tolerates_damage ()
	{
		var settings = profile_test_settings ();
		var root = profile_test_folder ();
		var profiles = new DockProfiles (settings, File.new_for_path (root));

		// Written by hand or by an older version
		try {
			FileUtils.set_contents (Path.build_filename (root, "viejo.ini"), """[Dock]
theme='Matte'
icon-size=4000
zoom-percent=no-es-un-numero
key-from-the-future=true
""");
		} catch (FileError e) {
			assert_not_reached ();
		}

		settings.set_int ("icon-size", 48);
		var zoom = settings.get_int ("zoom-percent");
		Test.expect_message (null, LogLevelFlags.LEVEL_WARNING, "*zoom-percent*");
		apply_profile (profiles, "viejo");
		Test.assert_expected_messages ();

		assert (settings.get_string ("theme") == "Matte");
		// Out of range and unreadable values leave the preference alone
		assert (settings.get_int ("icon-size") == 48);
		assert (settings.get_int ("zoom-percent") == zoom);

		remove_profile_test_folder (root);
	}

	void dock_profiles_apply_delayed ()
	{
		var settings = profile_test_settings ();
		var root = profile_test_folder ();
		var profiles = new DockProfiles (settings, File.new_for_path (root));

		settings.set_int ("icon-size", 72);
		save_profile (profiles, "grande");
		settings.set_int ("icon-size", 36);

		// A dock which delays its changes gets the profile at once
		settings.delay ();
		apply_profile (profiles, "grande");
		assert (!settings.has_unapplied);
		assert (settings.get_int ("icon-size") == 72);

		remove_profile_test_folder (root);
	}
}
