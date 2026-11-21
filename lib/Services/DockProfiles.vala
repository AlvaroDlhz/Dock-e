//
// Named sets of the preferences of a dock.
//

namespace Plank
{
	/**
	 * Keeps complete sets of preferences under a name, to return to later.
	 *
	 * A profile is a plain file with one line per preference. It holds the
	 * preferences only: the items on the dock and the style sheet of the
	 * user are not part of it.
	 */
	public class DockProfiles : Object
	{
		public const string FOLDER_NAME = "profiles";

		const string GROUP = "Dock";
		const string SUFFIX = ".ini";
		const int MAX_NAME_LENGTH = 40;

		GLib.Settings settings;
		File folder;
		string[]? names = null;
		FileMonitor? monitor;

		/**
		 * @param settings the preferences which are saved and brought back
		 * @param folder where the profiles are kept
		 */
		public DockProfiles (GLib.Settings settings, File folder)
		{
			this.settings = settings;
			this.folder = folder;
		}

		/**
		 * Whether a profile can be called this. The name becomes the name of
		 * a file, so nothing which leads out of the folder is accepted.
		 */
		public static bool is_valid_name (string name)
		{
			if (name == "" || name.char_count () > MAX_NAME_LENGTH || name.has_prefix ("."))
				return false;
			unichar c;
			for (var i = 0; name.get_next_char (ref i, out c);)
				if (!c.isalnum () && c != '-' && c != '_' && c != ' ')
					return false;
			return name.strip () == name;
		}

		/**
		 * The names of the saved profiles, in order.
		 */
		public string[] list ()
		{
			if (names != null)
				return names;

			string[] found = {};
			try {
				var directory = Dir.open (folder.get_path ());
				unowned string? entry;
				while ((entry = directory.read_name ()) != null) {
					if (!entry.has_suffix (SUFFIX))
						continue;
					var name = entry.substring (0, entry.length - SUFFIX.length);
					if (is_valid_name (name))
						found += name;
				}
			} catch (FileError e) {
				// No folder means no profiles yet
			}
			var sorted = new Gee.ArrayList<string>.wrap (found);
			sorted.sort ((a, b) => a.collate (b));
			names = sorted.to_array ();

			// Whatever is added or removed by hand is seen the next time
			if (monitor == null && folder.query_exists ()) {
				try {
					monitor = folder.monitor_directory (FileMonitorFlags.NONE);
					monitor.changed.connect (() => { names = null; });
				} catch (Error e) {
					debug ("Changes to the profiles will not be noticed: %s", e.message);
				}
			}
			return names;
		}

		/**
		 * Keeps the preferences as they are now under a name, replacing a
		 * profile of that name.
		 */
		public void save (string name) throws Error
		{
			if (!is_valid_name (name))
				throw new IOError.INVALID_FILENAME ("'%s' cannot be the name of a profile", name);

			var keys = new KeyFile ();
			foreach (unowned string key in settings.settings_schema.list_keys ())
				keys.set_string (GROUP, key, settings.get_value (key).print (false));

			if (!folder.query_exists ())
				folder.make_directory_with_parents ();
			FileUtils.set_contents (file_of (name), keys.to_data ());
			names = null;
		}

		/**
		 * Brings the preferences of a profile back. What the profile does not
		 * mention, or mentions in a way no longer understood, stays as it is.
		 */
		public void apply (string name) throws Error
		{
			if (!is_valid_name (name))
				throw new IOError.INVALID_FILENAME ("'%s' cannot be the name of a profile", name);

			var keys = new KeyFile ();
			keys.load_from_file (file_of (name), KeyFileFlags.NONE);
			var schema = settings.settings_schema;
			foreach (unowned string key in keys.get_keys (GROUP)) {
				if (!schema.has_key (key))
					continue;
				var schema_key = schema.get_key (key);
				try {
					var value = Variant.parse (schema_key.get_value_type (),
						keys.get_string (GROUP, key));
					if (schema_key.range_check (value) && !value.equal (settings.get_value (key)))
						settings.set_value (key, value);
				} catch (Error e) {
					warning ("Profile '%s' has no usable value for '%s': %s", name, key, e.message);
				}
			}
			if (settings.delay_apply)
				settings.apply ();
		}

		string file_of (string name)
		{
			return folder.get_child (name + SUFFIX).get_path ();
		}
	}
}
